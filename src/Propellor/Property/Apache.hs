module Propellor.Property.Apache where

import Propellor.Base
import qualified Propellor.Property.File as File
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.Service as Service
import qualified Propellor.Property.LetsEncrypt as LetsEncrypt

installed :: Property NoInfo
installed = Apt.installed ["apache2"]

restarted :: Property NoInfo
restarted = Service.restarted "apache2"

reloaded :: Property NoInfo
reloaded = Service.reloaded "apache2"

type ConfigLine = String

type ConfigFile = [ConfigLine]

siteEnabled :: Domain -> ConfigFile -> RevertableProperty NoInfo
siteEnabled domain cf = siteEnabled' domain cf <!> siteDisabled domain

siteEnabled' :: Domain -> ConfigFile -> Property NoInfo
siteEnabled' domain cf = combineProperties ("apache site enabled " ++ domain)
	[ siteAvailable domain cf
		`requires` installed
		`onChange` reloaded
	, check (not <$> isenabled) 
		(cmdProperty "a2ensite" ["--quiet", domain])
			`requires` installed
			`onChange` reloaded
	]
  where
	isenabled = boolSystem "a2query" [Param "-q", Param "-s", Param domain]

siteDisabled :: Domain -> Property NoInfo
siteDisabled domain = combineProperties
	("apache site disabled " ++ domain) 
	(map File.notPresent (siteCfg domain))
		`onChange` (cmdProperty "a2dissite" ["--quiet", domain] `assume` MadeChange)
		`requires` installed
		`onChange` reloaded

siteAvailable :: Domain -> ConfigFile -> Property NoInfo
siteAvailable domain cf = combineProperties ("apache site available " ++ domain) $
	map (`File.hasContent` (comment:cf)) (siteCfg domain)
  where
	comment = "# deployed with propellor, do not modify"

modEnabled :: String -> RevertableProperty NoInfo
modEnabled modname = enable <!> disable
  where
	enable = check (not <$> isenabled)
		(cmdProperty "a2enmod" ["--quiet", modname])
			`describe` ("apache module enabled " ++ modname)
			`requires` installed
			`onChange` reloaded
	disable = check isenabled
		(cmdProperty "a2dismod" ["--quiet", modname])
			`describe` ("apache module disabled " ++ modname)
			`requires` installed
			`onChange` reloaded
	isenabled = boolSystem "a2query" [Param "-q", Param "-m", Param modname]

-- | Make apache listen on the specified ports.
--
-- Note that ports are also specified inside a site's config file,
-- so that also needs to be changed.
listenPorts :: [Port] -> Property NoInfo
listenPorts ps = "/etc/apache2/ports.conf" `File.hasContent` map portline ps
	`onChange` restarted
  where
	portline (Port n) = "Listen " ++ show n

-- This is a list of config files because different versions of apache
-- use different filenames. Propellor simply writes them all.
siteCfg :: Domain -> [FilePath]
siteCfg domain =
	-- Debian pre-2.4
	[ "/etc/apache2/sites-available/" ++ domain
	-- Debian 2.4+
	, "/etc/apache2/sites-available/" ++ domain ++ ".conf"
	] 

-- | Configure apache to use SNI to differentiate between
-- https hosts.
--
-- This was off by default in apache 2.2.22. Newver versions enable
-- it by default. This property uses the filename used by the old version.
multiSSL :: Property NoInfo
multiSSL = check (doesDirectoryExist "/etc/apache2/conf.d") $
	"/etc/apache2/conf.d/ssl" `File.hasContent`
		[ "NameVirtualHost *:443"
		, "SSLStrictSNIVHostCheck off"
		]
		`describe` "apache SNI enabled"
		`onChange` reloaded

-- | Config file fragment that can be inserted into a <Directory>
-- stanza to allow global read access to the directory.
--
-- Works with multiple versions of apache that have different ways to do
-- it.
allowAll :: ConfigLine
allowAll = unlines
	[ "<IfVersion < 2.4>"
	, "Order allow,deny"
	, "allow from all"
	, "</IfVersion>"
	, "<IfVersion >= 2.4>"
	, "Require all granted"
	, "</IfVersion>"
	]

-- | Config file fragment that can be inserted into a <VirtualHost>
-- stanza to allow apache to display directory index icons.
iconDir :: ConfigLine
iconDir = unlines
	[ "<Directory \"/usr/share/apache2/icons\">"
	, "Options Indexes MultiViews"
	, "AllowOverride None"
	, allowAll
	, "  </Directory>"
	]

type WebRoot = FilePath

-- | A basic virtual host, publishing a directory, and logging to
-- the combined apache log file. Not https capable.
virtualHost :: Domain -> Port -> WebRoot -> RevertableProperty NoInfo
virtualHost domain (Port p) docroot = virtualHost' domain (Port p) docroot []

-- | Like `virtualHost` but with additional config lines added.
virtualHost' :: Domain -> Port -> WebRoot -> [ConfigLine] -> RevertableProperty NoInfo
virtualHost' domain (Port p) docroot addedcfg = siteEnabled domain $
	[ "<VirtualHost *:"++show p++">"
	, "ServerName "++domain++":"++show p
	, "DocumentRoot " ++ docroot
	, "ErrorLog /var/log/apache2/error.log"
	, "LogLevel warn"
	, "CustomLog /var/log/apache2/access.log combined"
	, "ServerSignature On"
	]
	++ addedcfg ++
	[ "</VirtualHost>"
	]

-- | A virtual host using https, with the certificate obtained
-- using `Propellor.Property.LetsEncrypt.letsEncrypt`.
--
-- http connections are redirected to https.
--
-- Example:
--
-- > httpsVirtualHost "example.com" "/var/www"
-- > 	(LetsEncrypt.AgreeTOS (Just "me@my.domain"))
httpsVirtualHost :: Domain -> WebRoot -> LetsEncrypt.AgreeTOS -> Property NoInfo
httpsVirtualHost domain docroot letos = httpsVirtualHost' domain docroot letos []

-- | Like `httpsVirtualHost` but with additional config lines added.
httpsVirtualHost' :: Domain -> WebRoot -> LetsEncrypt.AgreeTOS -> [ConfigLine] -> Property NoInfo
httpsVirtualHost' domain docroot letos addedcfg = setup
	`requires` modEnabled "rewrite"
	`requires` modEnabled "ssl"
	`before` LetsEncrypt.letsEncrypt letos domain docroot certinstaller
  where
	setup = siteEnabled' domain $
		-- The sslconffile is only created after letsencrypt gets
		-- the cert. The "*" is needed to make apache not error
		-- when the file doesn't exist.
		("IncludeOptional " ++ sslconffile "*")
		: vhost (Port 80)
			[ "RewriteEngine On"
			-- Pass through .well-known directory on http for the
			-- letsencrypt acme challenge.
			, "RewriteRule ^/.well-known/(.*) - [L]"
			-- Everything else redirects to https
			, "RewriteRule ^/(.*) https://" ++ domain ++ "/$1 [L,R,NE]"
			]
	certinstaller _domain certfile privkeyfile chainfile _fullchainfile =
		combineProperties (domain ++ " ssl cert installed")
			[ File.dirExists (takeDirectory cf)
			, File.hasContent cf $ vhost (Port 443)
				[ "SSLEngine on"
				, "SSLCertificateFile " ++ certfile
				, "SSLCertificateKeyFile" ++ privkeyfile
				, "SSLCertificateChainFile " ++ chainfile
				]
			-- always reload; the cert has changed
			, reloaded
			]
	  where
		cf = sslconffile "letsencrypt"
	sslconffile s = "/etc/apache2/sites-available/ssl/" ++ domain ++ "/" ++ s ++ ".conf"
	vhost (Port p) ls = 
		[ "<VirtualHost *:"++show p++">"
		, "ServerName "++domain++":"++show p
		, "DocumentRoot " ++ docroot
		, "ErrorLog /var/log/apache2/error.log"
		, "LogLevel warn"
		, "CustomLog /var/log/apache2/access.log combined"
		, "ServerSignature On"
		] ++ ls ++ addedcfg ++
		[ "</VirtualHost>"
		]
