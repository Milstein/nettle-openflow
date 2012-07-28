{-
A simple controller that responds to each packet-in message by 
installing a flow rule to process the packet-in packet and similar packets
using the switch's Flood port. The rule is installed with a 5 second hard (and inactivity)
timeout so the rule should be removed by the switch after 5 seconds.

This controller uses the Nettle.Servers.Server module and forks a Haskell thread 
for every connecting OpenFlow switch. 
-}

import Nettle.Servers.Server
import Nettle.OpenFlow
import Control.Concurrent
import qualified Data.ByteString as B
import System.Environment

main :: IO ()
main =
  do portNum <- getPortNumber
     ofpServer <- startOpenFlowServer Nothing portNum
     forever (do (switch,sfr) <- acceptSwitch ofpServer
                 forkIO (handleSwitch switch)
             )
     closeServer ofpServer
       
       
getPortNumber :: IO ServerPortNumber       
getPortNumber 
  = do args <- getArgs
       if length args < 1 
         then error "Requires one command-line argument specifying the server port number."
         else return (read (args !! 0))


handleSwitch :: SwitchHandle -> IO ()
handleSwitch switch 
  = do untilNothing (receiveFromSwitch switch) (messageHandler switch)
       closeSwitchHandle switch


messageHandler :: SwitchHandle -> (TransactionID, SCMessage) -> IO ()
messageHandler switch (xid, scmsg) =
  case scmsg of
    PacketIn pkt        -> 
      case enclosedFrame pkt of 
        Left s -> putStrLn (s ++ ": " ++ show (B.unpack (packetData pkt)))
        Right frame -> 
          let flowEntry = AddFlow { match             = frameToExactMatch (receivedOnPort pkt) frame
                                  , priority          = 32768
                                  , actions           = [SendOutPort Flood]
                                  , cookie            = 0
                                  , idleTimeOut       = ExpireAfter 5
                                  , hardTimeOut       = ExpireAfter 5
                                  , notifyWhenRemoved = False
                                  , applyToPacket     = bufferID pkt
                                  , overlapAllowed    = False
                                  } 
          in sendToSwitch switch (xid, FlowMod flowEntry)
    _                   -> return ()

