module Propellor.CmdLine where

import System.Environment (getArgs)
import Data.List
import System.Exit
import System.Log.Logger
import System.Log.Formatter
import System.Log.Handler (setFormatter, LogHandler)
import System.Log.Handler.Simple
import System.PosixCompat

import Propellor
import qualified Propellor.Property.Docker as Docker
import Utility.FileMode
import Utility.SafeCommand

usage :: IO a
usage = do
	putStrLn $ unlines 
		[ "Usage:"
		, "  propellor"
		, "  propellor hostname"
		, "  propellor --spin hostname"
		, "  propellor --set hostname field"
		, "  propellor --add-key keyid"
		]
	exitFailure

processCmdLine :: IO CmdLine
processCmdLine = go =<< getArgs
  where
  	go ("--help":_) = usage
  	go ("--spin":h:[]) = return $ Spin h
  	go ("--boot":h:[]) = return $ Boot h
	go ("--add-key":k:[]) = return $ AddKey k
	go ("--set":h:f:[]) = case readish f of
		Just pf -> return $ Set h pf
		Nothing -> errorMessage $ "Unknown privdata field " ++ f
	go ("--continue":s:[]) = case readish s of
		Just cmdline -> return $ Continue cmdline
		Nothing -> errorMessage "--continue serialization failure"
  	go ("--chain":h:[]) = return $ Chain h
	go ("--docker":h:[]) = return $ Docker h
	go (h:[])
		| "--" `isPrefixOf` h = usage
		| otherwise = return $ Run h
	go [] = do
		s <- takeWhile (/= '\n') <$> readProcess "hostname" ["-f"]
		if null s
			then errorMessage "Cannot determine hostname! Pass it on the command line."
			else return $ Run s
	go _ = usage

defaultMain :: [HostName -> Maybe [Property]] -> IO ()
defaultMain getprops = do
	checkDebugMode
	cmdline <- processCmdLine
	debug ["command line: ", show cmdline]
	go True cmdline
  where
	go _ (Continue cmdline) = go False cmdline
	go _ (Set host field) = setPrivData host field
	go _ (AddKey keyid) = addKey keyid
	go _ (Chain host) = withprops host $ \ps -> do
		r <- ensureProperties' ps
		putStrLn $ "\n" ++ show r
	go _ (Docker host) = Docker.chain host
	go True cmdline@(Spin _) = buildFirst cmdline $ go False cmdline
	go True cmdline = updateFirst cmdline $ go False cmdline
	go False (Spin host) = withprops host $ const $ spin host
	go False (Run host) = ifM ((==) 0 <$> getRealUserID)
		( withprops host ensureProperties
		, go True (Spin host)
		)
	go False (Boot host) = withprops host $ boot

	withprops host a = maybe (unknownhost host) a $
		headMaybe $ catMaybes $ map (\get -> get host) getprops

unknownhost :: HostName -> IO a
unknownhost h = errorMessage $ unlines
	[ "Unknown host: " ++ h
	, "(Perhaps you should specify the real hostname on the command line?)"
	, "(Or, edit propellor's config.hs to configure this host)"
	]

buildFirst :: CmdLine -> IO () -> IO ()
buildFirst cmdline next = do
	oldtime <- getmtime
	ifM (actionMessage "Propellor build" $ boolSystem "make" [Param "build"])
		( do
			newtime <- getmtime
			if newtime == oldtime
				then next
				else void $ boolSystem "./propellor" [Param "--continue", Param (show cmdline)]
		, errorMessage "Propellor build failed!" 
		)
  where
	getmtime = catchMaybeIO $ getModificationTime "propellor"

getCurrentBranch :: IO String
getCurrentBranch = takeWhile (/= '\n') 
	<$> readProcess "git" ["symbolic-ref", "--short", "HEAD"]

updateFirst :: CmdLine -> IO () -> IO ()
updateFirst cmdline next = do
	branchref <- getCurrentBranch
	let originbranch = "origin" </> branchref

	void $ actionMessage "Git fetch" $ boolSystem "git" [Param "fetch"]
	
	whenM (doesFileExist keyring) $ do
		{- To verify origin branch commit's signature, have to
		 - convince gpg to use our keyring. While running git log.
		 - Which has no way to pass options to gpg.
		 - Argh! -}
		let gpgconf = privDataDir </> "gpg.conf"
		writeFile gpgconf $ unlines
			[ " keyring " ++ keyring
			, "no-auto-check-trustdb"
			]
		-- gpg is picky about perms
		modifyFileMode privDataDir (removeModes otherGroupModes)
		s <- readProcessEnv "git" ["log", "-n", "1", "--format=%G?", originbranch]
			(Just [("GNUPGHOME", privDataDir)])
		nukeFile $ privDataDir </> "trustdb.gpg"
		nukeFile $ privDataDir </> "pubring.gpg"
		nukeFile $ privDataDir </> "gpg.conf"
		if s == "U\n" || s == "G\n"
			then do
				putStrLn $ "git branch " ++ originbranch ++ " gpg signature verified; merging"
				hFlush stdout
			else errorMessage $ "git branch " ++ originbranch ++ " is not signed with a trusted gpg key; refusing to deploy it!"
	
	oldsha <- getCurrentGitSha1 branchref
	void $ boolSystem "git" [Param "merge", Param originbranch]
	newsha <- getCurrentGitSha1 branchref

	if oldsha == newsha
		then next
		else ifM (actionMessage "Propellor build" $ boolSystem "make" [Param "build"])
			( void $ boolSystem "./propellor" [Param "--continue", Param (show cmdline)]
			, errorMessage "Propellor build failed!" 
			)

getCurrentGitSha1 :: String -> IO String
getCurrentGitSha1 branchref = readProcess "git" ["show-ref", "--hash", branchref]

spin :: HostName -> IO ()
spin host = do
	url <- getUrl
	void $ gitCommit [Param "--allow-empty", Param "-a", Param "-m", Param "propellor spin"]
	void $ boolSystem "git" [Param "push"]
	go url =<< gpgDecrypt (privDataFile host)
  where
	go url privdata = withBothHandles createProcessSuccess (proc "ssh" [user, bootstrapcmd]) $ \(toh, fromh) -> do
		let finish = do
			senddata toh (privDataFile host) privDataMarker privdata
			hClose toh
			
			-- Display remaining output.
			void $ tryIO $ forever $
				showremote =<< hGetLine fromh
			hClose fromh
		status <- getstatus fromh `catchIO` (const $ errorMessage "protocol error (perhaps the remote propellor failed to run?)")
		case status of
			Ready -> finish
			NeedGitClone -> do
				hClose toh
				hClose fromh
				sendGitClone host url
				go url privdata
	
	user = "root@"++host

	bootstrapcmd = shellWrap $ intercalate " ; "
		[ "if [ ! -d " ++ localdir ++ " ]"
		, "then " ++ intercalate " && "
			[ "apt-get -y install git"
			, "echo " ++ toMarked statusMarker (show NeedGitClone)
			]
		, "else " ++ intercalate " && "
			[ "cd " ++ localdir
			, "if ! test -x ./propellor; then make build; fi"
			, "./propellor --boot " ++ host
			]
		, "fi"
		]

	getstatus :: Handle -> IO BootStrapStatus
	getstatus h = do
		l <- hGetLine h
		case readish =<< fromMarked statusMarker l of
			Nothing -> do
				showremote l
				getstatus h
			Just status -> return status
	
	showremote s = putStrLn s
	senddata toh f marker s = void $
		actionMessage ("Sending " ++ f ++ " (" ++ show (length s) ++ " bytes) to " ++ host) $ do
			sendMarked toh marker s
			return True

sendGitClone :: HostName -> String -> IO ()
sendGitClone host url = void $ actionMessage ("Pushing git repository to " ++ host) $ do
	branch <- getCurrentBranch
	withTmpFile "propellor.git" $ \tmp _ -> allM id
		-- TODO: ssh connection caching, or better push method
		-- with less connections.
		[ boolSystem "git" [Param "bundle", Param "create", File tmp, Param "HEAD"]
		, boolSystem "scp" [File tmp, Param ("root@"++host++":"++remotebundle)]
		, boolSystem "ssh" [Param ("root@"++host), Param $ unpackcmd branch]
		]
  where
	remotebundle = "/usr/local/propellor.git"
	unpackcmd branch = shellWrap $ intercalate " && "
		[ "git clone " ++ remotebundle ++ " " ++ localdir
		, "cd " ++ localdir
		, "git checkout -b " ++ branch
		, "git remote rm origin"
		, "rm -f " ++ remotebundle
		, "git remote add origin " ++ url
		-- same as --set-upstream-to, except origin branch
		-- has not been pulled yet
		, "git config branch."++branch++".remote origin"
		, "git config branch."++branch++".merge refs/heads/"++branch
		]

data BootStrapStatus = Ready | NeedGitClone
	deriving (Read, Show, Eq)

type Marker = String
type Marked = String

statusMarker :: Marker
statusMarker = "STATUS"

privDataMarker :: String
privDataMarker = "PRIVDATA "

toMarked :: Marker -> String -> String
toMarked marker = intercalate "\n" . map (marker ++) . lines

sendMarked :: Handle -> Marker -> String -> IO ()
sendMarked h marker s = do
	-- Prefix string with newline because sometimes a
	-- incomplete line is output.
	hPutStrLn h ("\n" ++ toMarked marker s)
	hFlush h

fromMarked :: Marker -> Marked -> Maybe String
fromMarked marker s
	| null matches = Nothing
	| otherwise = Just $ intercalate "\n" $
		map (drop len) matches
  where
	len = length marker
	matches = filter (marker `isPrefixOf`) $ lines s

boot :: [Property] -> IO ()
boot ps = do
	sendMarked stdout statusMarker $ show Ready
	reply <- hGetContentsStrict stdin

	makePrivDataDir
	maybe noop (writeFileProtected privDataLocal) $
		fromMarked privDataMarker reply
	ensureProperties ps

addKey :: String -> IO ()
addKey keyid = exitBool =<< allM id [ gpg, gitadd, gitcommit ]
  where
	gpg = boolSystem "sh"
		[ Param "-c"
		, Param $ "gpg --export " ++ keyid ++ " | gpg " ++
			unwords (gpgopts ++ ["--import"])
		]
	gitadd = boolSystem "git"
		[ Param "add"
		, File keyring
		]
	gitcommit = gitCommit
		[ File keyring
		, Param "-m"
		, Param "propellor addkey"
		]

{- Automatically sign the commit if there'a a keyring. -}
gitCommit :: [CommandParam] -> IO Bool
gitCommit ps = do
	k <- doesFileExist keyring
	boolSystem "git" $ catMaybes $
		[ Just (Param "commit")
		, if k then Just (Param "--gpg-sign") else Nothing
		] ++ map Just ps

keyring :: FilePath
keyring = privDataDir </> "keyring.gpg"

gpgopts :: [String]
gpgopts = ["--options", "/dev/null", "--no-default-keyring", "--keyring", keyring]

getUrl :: IO String
getUrl = maybe nourl return =<< getM get urls
  where
	urls = ["remote.deploy.url", "remote.origin.url"]
	nourl = errorMessage $ "Cannot find deploy url in " ++ show urls
	get u = do
		v <- catchMaybeIO $ 
			takeWhile (/= '\n') 
				<$> readProcess "git" ["config", u]
		return $ case v of
			Just url | not (null url) -> Just url
			_ -> Nothing

checkDebugMode :: IO ()
checkDebugMode = go =<< getEnv "PROPELLOR_DEBUG"
  where
	go (Just s)
		| s == "1" = do
			f <- setFormatter
				<$> streamHandler stderr DEBUG
				<*> pure (simpleLogFormatter "[$time] $msg")
			updateGlobalLogger rootLoggerName $ 
				setLevel DEBUG .  setHandlers [f]
	go _ = noop
