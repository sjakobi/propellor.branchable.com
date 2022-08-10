{-# OPTIONS_GHC -ddump-timings #-}

-- | Specific configuration for Joey Hess's sites. Probably not useful to
-- others except as an example.

{-# LANGUAGE FlexibleContexts, TypeFamilies #-}

module Propellor.Property.SiteSpecific.JoeySites where

import Propellor.Base
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.File as File
import qualified Propellor.Property.Ssh as Ssh
import qualified Propellor.Property.Git as Git
import qualified Propellor.Property.Cron as Cron
import qualified Propellor.Property.User as User
import qualified Propellor.Property.Group as Group
import qualified Propellor.Property.Apache as Apache
import qualified Propellor.Property.Systemd as Systemd

import System.Posix.Files

house :: IsContext c => User -> [Host] -> c -> (SshKeyType, Ssh.PubKeyText) -> Property (HasInfo + DebianLike)
house user hosts ctx sshkey = propertyList "home automation" $ props
	& Apache.installed
	& Git.cloned user "https://git.joeyh.name/git/joey/house.git" d Nothing
	& websitesymlink
	& build
	& Systemd.enabled pollerservicename
		`requires` pollerserviceinstalled
		`onChange` Systemd.started pollerservicename
	& Systemd.enabled controllerservicename
		`requires` controllerserviceinstalled
		`onChange` Systemd.started controllerservicename
	& Systemd.enabled watchdogservicename
		`requires` watchdogserviceinstalled
		`onChange` Systemd.started watchdogservicename
	& Apt.serviceInstalledRunning "watchdog"
	& User.hasGroup user (Group "dialout")
	& Group.exists (Group "gpio") Nothing
	& User.hasGroup user (Group "gpio")
	& Apt.installed ["i2c-tools"]
	& User.hasGroup user (Group "i2c")
	& "/etc/modules-load.d/house.conf" `File.hasContent` ["i2c-dev"]
	& Cron.niceJob "house upload"
		(Cron.Times "1 * * * *") user d rsynccommand
		`requires` Ssh.userKeyAt (Just sshkeyfile) user ctx sshkey
		`requires` File.ownerGroup (takeDirectory sshkeyfile)
			user (userGroup user)
		`requires` File.dirExists (takeDirectory sshkeyfile)
		`requires` Ssh.knownHost hosts "kitenet.net" user
	& File.hasPrivContentExposed "/etc/darksky-forecast-url" anyContext
  where
	d = "/home/joey/house"
	sshkeyfile = d </> ".ssh/key"
	build = check (not <$> doesFileExist (d </> "controller")) $
		userScriptProperty (User "joey")
			[ "cd " ++ d
			, "cabal update"
			, "make"
			]
		`assume` MadeChange
		`requires` Apt.installed
			[ "ghc", "cabal-install", "make"
			, "libghc-http-types-dev"
			, "libghc-aeson-dev"
			, "libghc-wai-dev"
			, "libghc-warp-dev"
			, "libghc-http-client-dev"
			, "libghc-http-client-tls-dev"
			, "libghc-reactive-banana-dev"
			, "libghc-hinotify-dev"
			]
	pollerservicename = "house-poller"
	pollerservicefile = "/etc/systemd/system/" ++ pollerservicename ++ ".service"
	pollerserviceinstalled = pollerservicefile `File.hasContent`
		[ "[Unit]"
		, "Description=house poller"
		, ""
		, "[Service]"
		, "ExecStart=" ++ d ++ "/poller"
		, "WorkingDirectory=" ++ d
		, "User=joey"
		, "Group=joey"
		, "Restart=always"
		, ""
		, "[Install]"
		, "WantedBy=multi-user.target"
		, "WantedBy=house-controller.target"
		]
	controllerservicename = "house-controller"
	controllerservicefile = "/etc/systemd/system/" ++ controllerservicename ++ ".service"
	controllerserviceinstalled = controllerservicefile `File.hasContent`
		[ "[Unit]"
		, "Description=house controller"
		, ""
		, "[Service]"
		, "ExecStart=" ++ d ++ "/controller"
		, "WorkingDirectory=" ++ d
		, "User=joey"
		, "Group=joey"
		, "Restart=always"
		, ""
		, "[Install]"
		, "WantedBy=multi-user.target"
		]
	watchdogservicename = "house-watchdog"
	watchdogservicefile = "/etc/systemd/system/" ++ watchdogservicename ++ ".service"
	watchdogserviceinstalled = watchdogservicefile `File.hasContent`
		[ "[Unit]"
		, "Description=house watchdog"
		, ""
		, "[Service]"
		, "ExecStart=" ++ d ++ "/watchdog"
		, "WorkingDirectory=" ++ d
		, "User=root"
		, "Group=root"
		, "Restart=always"
		, ""
		, "[Install]"
		, "WantedBy=multi-user.target"
		]
	-- Any changes to the rsync command will need my .authorized_keys
	-- rsync server command to be updated too.
	rsynccommand = "rsync -e 'ssh -i" ++ sshkeyfile ++ "' -avz rrds/ joey@kitenet.net:/srv/web/house.joeyh.name/rrds/ >/dev/null 2>&1"

	websitesymlink :: Property UnixLike
	websitesymlink = check (not . isSymbolicLink <$> getSymbolicLinkStatus "/var/www/html")
		(property "website symlink" $ makeChange $ do
			removeDirectoryRecursive "/var/www/html"
			createSymbolicLink d "/var/www/html"
		)
