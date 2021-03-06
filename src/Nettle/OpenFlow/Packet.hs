{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP, DisambiguateRecordFields, RecordWildCards #-}

module Nettle.OpenFlow.Packet (
  -- * Sending packets
  PacketOut (..)
  , bufferedPacketOut
  , unbufferedPacketOut
  , receivedPacketOut
  , BufferID
    
    -- * Packets not handled by a switch
  , PacketInfo (..)
  , PacketInReason (..) 
  , NumBytes
  , bufferedAtSwitch
  ) where

import qualified Data.ByteString.Lazy as B
import Nettle.OpenFlow.Port
import Nettle.OpenFlow.Action
import Nettle.Ethernet.EthernetFrame
import Data.Word
import Data.Maybe (isJust)

-- | A switch can be remotely commanded to send a packet. The packet
-- can either be a packet buffered at the switch, in which case the
-- bufferID is provided, or it can be specified explicitly by giving 
-- the packet data.
data PacketOut 
    = PacketOutRecord {
        bufferIDData  :: !(Either BufferID B.ByteString),   -- ^either a buffer ID or the data itself
        packetInPort  :: !(Maybe PortID),                   -- ^the port at which the packet received, for the purposes of processing this command
        packetActions :: !ActionSequence                  -- ^actions to apply to the packet
      } deriving (Eq,Show)

-- |A switch may buffer a packet that it receives. 
-- When it does so, the packet is assigned a bufferID
-- which can be used to refer to that packet.
type BufferID = Word32

-- | Constructs a @PacketOut@ value for a packet buffered at a switch.
bufferedPacketOut :: BufferID -> Maybe PortID -> ActionSequence -> PacketOut
bufferedPacketOut bufID inPort actions = 
  PacketOutRecord { bufferIDData = Left bufID
                  , packetInPort       = inPort
                  , packetActions      = actions
                  } 

-- | Constructs a @PacketOut@ value for an unbuffered packet, including the packet data.
unbufferedPacketOut :: B.ByteString -> Maybe PortID -> ActionSequence -> PacketOut
unbufferedPacketOut pktData inPort actions  = 
  PacketOutRecord { bufferIDData = Right pktData
                  , packetInPort       = inPort
                  , packetActions      = actions
                  } 

-- | Constructs a @PacketOut@ value that processes the packet referred to by the @PacketInfo@ value 
-- according to the specified actions. 
receivedPacketOut :: PacketInfo -> ActionSequence -> PacketOut
receivedPacketOut (PacketInfo {..}) actions = 
    case bufferID of 
      Nothing    -> unbufferedPacketOut packetData (Just receivedOnPort) actions
      Just bufID -> bufferedPacketOut bufID (Just receivedOnPort) actions


-- | A switch receives packets on its ports. If the packet matches
-- some flow rules, the highest priority rule is executed. If no 
-- flow rule matches, the packet is sent to the controller. When 
-- packet is sent to the controller, the switch sends a message
-- containing the following information.
data PacketInfo 
    = PacketInfo {
        bufferID       :: !(Maybe BufferID), -- ^buffer ID if packet buffered
        packetLength   :: !NumBytes,       -- ^full length of frame
        receivedOnPort :: !PortID,         -- ^port on which frame was received
        reasonSent     :: !PacketInReason, -- ^reason packet is being sent
        packetData     :: !B.ByteString,   -- ^ethernet frame, includes full packet only if no buffer ID
        enclosedFrame  :: !(Either String EthernetFrame) -- ^result of parsing packetData field.
      } deriving (Show,Eq)


-- |A PacketInfo message includes the reason that the message
-- was sent, namely either there was no match, or there was
-- a match, and that match's actions included a Sent-To-Controller
-- action.
data PacketInReason = NotMatched | ExplicitSend deriving (Show,Read,Eq,Ord,Enum)

-- | The number of bytes in a packet.
type NumBytes = Int

bufferedAtSwitch :: PacketInfo -> Bool
bufferedAtSwitch = isJust . bufferID
