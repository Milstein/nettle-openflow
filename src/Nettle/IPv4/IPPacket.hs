{-# LANGUAGE TypeSynonymInstances, TypeOperators, MultiParamTypeClasses, FunctionalDependencies, RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

{-|

This module provides @Get@ values for parsing various 
IP packets and headers from ByteStrings into a byte-sequence-independent 
representation as Haskell datatypes. 

Warning: 

These are incomplete. The headers may not contain all the information
that the protocols specify. For example, the Haskell representation of an IP Header
only includes source and destination addresses and IP protocol number, even though
an IP packet has many more header fields. More seriously, an IP header may have an optional 
extra headers section after the destination address. We assume this is not present. If it is present, 
then the transport protocol header will not be directly after the destination address, but will be after 
these options. Therefore functions that assume this, such as the getExactMatch function below, will give 
incorrect results when applied to such IP packets. 

The Haskell representations of the headers for the transport protocols are similarly incomplete. 
Again, the Get instances for the transport protocols may not parse through the end of the 
transport protocol header. 

-}
module Nettle.IPv4.IPPacket ( 
  -- * IP Packet 
  IPPacket(..)
  , IPHeader(..)
  , DifferentiatedServicesCodePoint
  , FragOffset
  , IPProtocol
  , IPTypeOfService
  , TransportPort
  , ipTypeTcp 
  , ipTypeUdp 
  , ipTypeIcmp
  , IPBody(..)
  , fromTCPPacket
  , fromUDPPacket
  , withIPPacket
  , foldIPPacket
  , foldIPBody
    
    -- * Parsers
  , getIPPacket
  , getIPHeader
  , ICMPHeader
  , ICMPType
  , ICMPCode
  , getICMPHeader
  , TCPHeader
  , TCPPortNumber
  , getTCPHeader
  , UDPHeader
  , UDPPortNumber
  , getUDPHeader
  ) where

import Nettle.IPv4.IPAddress
import Data.Bits
import Data.Word
import qualified Data.ByteString.Lazy as B
import Data.HList
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put

-- | An IP packet consists of a header and a body.
type IPPacket = IPHeader :*: IPBody :*: HNil


-- | An IP Header includes various information about the packet, including the type of payload it contains. 
-- Warning: this definition does not include every header field included in an IP packet. 
data IPHeader = IPHeader { ipSrcAddress  :: !IPAddress
                         , ipDstAddress  :: !IPAddress
                         , ipProtocol    :: !IPProtocol  
                         , headerLength  :: !Int
                         , totalLength   :: !Int
                         , dscp          :: !DifferentiatedServicesCodePoint -- ^ differentiated services code point - 6 bit number
                         }
                deriving (Read,Show,Eq)

type DifferentiatedServicesCodePoint = Word8
type FragOffset      = Word16
type IPProtocol      = Word8
type IPTypeOfService = Word8
type TransportPort   = Word16

ipTypeTcp, ipTypeUdp, ipTypeIcmp :: IPProtocol

ipTypeTcp  = 6
ipTypeUdp  = 17
ipTypeIcmp = 1

-- | The body of an IP packet can be either a TCP, UDP, ICMP or other packet. 
-- Packets other than TCP, UDP, ICMP are represented as unparsed @ByteString@ values.
data IPBody   = TCPInIP TCPHeader
              | UDPInIP UDPHeader B.ByteString
              | ICMPInIP ICMPHeader
              | UninterpretedIPBody B.ByteString 
              deriving (Show,Eq)


foldIPPacket :: (IPHeader -> IPBody -> a) -> IPPacket -> a
foldIPPacket f (HCons h (HCons b HNil)) = f h b

foldIPBody :: (TCPHeader -> a) -> (UDPHeader -> a) -> (ICMPHeader -> a) -> (B.ByteString -> a) -> IPBody -> a
foldIPBody f g h k (TCPInIP x) = f x
foldIPBody f g h k (UDPInIP x body) = g x
foldIPBody f g h k (ICMPInIP x) = h x
foldIPBody f g h k (UninterpretedIPBody x) = k x


fromTCPPacket :: IPBody -> Maybe (TCPHeader :*: HNil)
fromTCPPacket (TCPInIP body) = Just (hCons body hNil)
fromTCPPacket _ = Nothing


fromUDPPacket :: IPBody -> Maybe (UDPHeader :*: B.ByteString :*: HNil)
fromUDPPacket (UDPInIP hdr body) = Just (hCons hdr (hCons body hNil))
fromUDPPacket _ = Nothing


withIPPacket :: HList l => (IPBody -> Maybe l) -> IPPacket -> Maybe (IPHeader :*: l)
withIPPacket f pkt = fmap (hCons (hOccurs pkt)) (f (hOccurs pkt))

getIPHeader :: Get IPHeader
getIPHeader = do 
  b1                 <- getWord8
  diffServ           <- getWord8
  totalLen           <- getWord16be
  ident              <- getWord16be
  flagsAndFragOffset <- getWord16be
  ttl                <- getWord8
  nwproto            <- getIPProtocol
  hdrChecksum        <- getWord16be
  nwsrc              <- get
  nwdst              <- get
  return (IPHeader { ipSrcAddress = nwsrc 
                   , ipDstAddress = nwdst 
                   , ipProtocol = nwproto
                   , headerLength = fromIntegral (b1 .&. 0x0f)
                   , totalLength  = fromIntegral totalLen
                   , dscp = shiftR diffServ 2
                   } )
{-# INLINE getIPHeader #-}


getIPProtocol :: Get IPProtocol 
getIPProtocol = getWord8
{-# INLINE getIPProtocol #-}

getIPPacket :: Get IPPacket 
getIPPacket = do 
  hdr  <- {-# SCC "getIPPacket1" #-} getIPHeader
  body <- {-# SCC "getIPPacket2" #-} getIPBody hdr
  return body
    where getIPBody hdr@(IPHeader {..}) 
              | ipProtocol == ipTypeTcp  = do
                  tcpHdr <- getTCPHeader
                  return (hCons hdr (hCons (TCPInIP tcpHdr) hNil))
              | ipProtocol == ipTypeUdp  = do
                  udpHdr <- getUDPHeader  
                  body <- getLazyByteString (fromIntegral (totalLength - (4 * headerLength)) - 4)
                  return (hCons hdr (hCons (UDPInIP udpHdr body) hNil))
              | ipProtocol == ipTypeIcmp =  getICMPHeader >>= return . (\icmpHdr -> hCons hdr (hCons (ICMPInIP icmpHdr) hNil))
              | otherwise                = do
                  bs <- getLazyByteString (fromIntegral (totalLength - (4 * headerLength)))
                  return (hCons hdr (hCons (UninterpretedIPBody bs) hNil))
{-# INLINE getIPPacket #-}
          

-- Transport Header

type ICMPHeader = (ICMPType, ICMPCode)
type ICMPType = Word8
type ICMPCode = Word8

getICMPHeader :: Get ICMPHeader
getICMPHeader = do 
  icmp_type <- getWord8
  icmp_code <- getWord8
  skip 6
  return (icmp_type, icmp_code)
{-# INLINE getICMPHeader #-}  

getICMPHeader2 :: Get ICMPHeader
getICMPHeader2 = do 
  icmp_type <- getWord8
  icmp_code <- getWord8
  skip 6
  return (icmp_type, icmp_code)

type TCPHeader  = (TCPPortNumber, TCPPortNumber)
type TCPPortNumber = Word16

getTCPHeader :: Get TCPHeader
getTCPHeader = do 
  srcp <- getWord16be
  dstp <- getWord16be
  return (srcp,dstp)
{-# INLINE getTCPHeader #-}  

type UDPHeader     = (UDPPortNumber, UDPPortNumber)
type UDPPortNumber = Word16

getUDPHeader :: Get UDPHeader
getUDPHeader = do 
  srcp <- getWord16be
  dstp <- getWord16be
  return (srcp,dstp)
{-# INLINE getUDPHeader #-}  

