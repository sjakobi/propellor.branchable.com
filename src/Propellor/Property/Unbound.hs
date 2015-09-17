-- | Properties for the Unbound caching DNS server

module Propellor.Property.Unbound
	( installed
	, restarted
	, reloaded
	, cachingDnsServer
	) where

import Propellor
import Propellor.Property.File
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.Service as Service

import Data.List (find)


type ConfSection = String

type UnboundSetting = (UnboundKey, UnboundValue)

type UnboundSection = (ConfSection, [UnboundSetting])

type UnboundZone = (BindDomain, ZoneType)

type UnboundHost = (BindDomain, Record)

type UnboundKey = String

type UnboundValue = String

type ZoneType = String

installed :: Property NoInfo
installed = Apt.installed ["unbound"]

restarted :: Property NoInfo
restarted = Service.restarted "unbound"

reloaded :: Property NoInfo
reloaded = Service.reloaded "unbound"

dValue :: BindDomain -> String
dValue (RelDomain d) = d
dValue (AbsDomain d) = d ++ "."
dValue (RootDomain) = "@"

sectionHeader :: ConfSection -> String
sectionHeader header = header ++ ":"

config :: FilePath
config = "/etc/unbound/unbound.conf.d/propellor.conf"

cachingDnsServer :: [UnboundSection] -> [UnboundZone] -> [UnboundHost] -> Property NoInfo
cachingDnsServer sections zones hosts =
	config `hasContent` (comment : otherSections ++ serverSection)
	`onChange` restarted
  where
	comment = "# deployed with propellor, do not modify"
	serverSection = genSection (fromMaybe ("server", []) $ find ((== "server") . fst) sections)
		++ map genZone zones
		++ map (uncurry genRecord') hosts
	otherSections = foldr ((++) . genSection) [] sections

genSection :: UnboundSection -> [Line]
genSection (section, settings) = sectionHeader section : map genSetting settings

genSetting :: UnboundSetting -> Line
genSetting (key, value) = "    " ++ key ++ ": " ++ value

genZone :: UnboundZone -> Line
genZone (dom, zt) = "    local-zone: \"" ++ dValue dom ++ "\" " ++ zt

genRecord' :: BindDomain -> Record -> Line
genRecord' dom r = "    local-data: \"" ++ fromMaybe "" (genRecord dom r) ++ "\""

genRecord :: BindDomain -> Record -> Maybe String
genRecord dom (Address addr) = Just $ genAddressNoTtl dom addr
genRecord dom (MX priority dest) = Just $ genMX dom priority dest
genRecord dom (PTR revip) = Just $ genPTR dom revip
genRecord _ (CNAME _) = Nothing
genRecord _ (NS _) = Nothing
genRecord _ (TXT _) = Nothing
genRecord _ (SRV _ _ _ _) = Nothing
genRecord _ (SSHFP _ _ _) = Nothing
genRecord _ (INCLUDE _) = Nothing

genAddressNoTtl :: BindDomain -> IPAddr -> String
genAddressNoTtl dom = genAddress dom Nothing

genAddress :: BindDomain -> Maybe Int -> IPAddr -> String
genAddress dom ttl addr = case addr of
	IPv4 _ -> genAddress' "A" dom ttl addr
	IPv6 _ -> genAddress' "AAAA" dom ttl addr

genAddress' :: String -> BindDomain -> Maybe Int -> IPAddr -> String
genAddress' recordtype dom ttl addr = dValue dom ++ " " ++ maybe "" (\ttl' -> show ttl' ++ " ") ttl ++ "IN " ++ recordtype ++ " " ++ fromIPAddr addr

genMX :: BindDomain -> Int -> BindDomain -> String
genMX dom priority dest = dValue dom ++ " " ++ "MX" ++ " " ++ show priority ++ " " ++ dValue dest

genPTR :: BindDomain -> ReverseIP -> String
genPTR dom revip = revip ++ ". " ++ "PTR" ++ " " ++ dValue dom
