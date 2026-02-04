module Main (main) where

import Snapshot.Routing.Decode (decodeRoutingContext)
import Snapshot.Routing.Types (RoutingContext(..))
import Snapshot.Scheduler.Network.Sim
import Snapshot.Scheduler.Types
import Snapshot.Scheduler.Union (unionWorkSets)

import qualified Data.ByteString as BS
import Data.Word (Word8, Word32)
import Test.QuickCheck

main :: IO ()
main = do
  ctxBytes <- BS.readFile "test/golden-network/routing-epoch0.ctx"
  ctx <- case decodeRoutingContext ctxBytes of
    Left err -> error ("decodeRoutingContext failed: " ++ show err)
    Right c -> pure c
  let args = stdArgs { maxSuccess = 50, maxSize = 8 }
  runQC args "eventual_convergence" (prop_eventual_convergence ctx)

runQC :: Testable prop => Args -> String -> prop -> IO ()
runQC args name prop = do
  putStrLn ("Running " ++ name ++ "...")
  quickCheckWith args prop

prop_eventual_convergence :: RoutingContext -> Property
prop_eventual_convergence ctx =
  forAll (genCluster ctx) $ \nodes ->
    case convergeSteps 10 ctx nodes of
      Left _ -> property False
      Right finalNodes ->
        let expected = expectedUnion nodes
            allEqual = all (== expected) (map simWork finalNodes)
        in property allEqual

genCluster :: RoutingContext -> Gen [SimNode]
genCluster ctx = do
  let peers = take 4 (routingPeers ctx)
  n <- elements [2,3,4]
  let chosen = take n peers
  items <- genWorkItems
  assigns <- vectorOf (length items) (chooseInt (0, n - 1))
  let buckets = bucketItems n items assigns
  pure [ SimNode p (canonicalizeWorkSet ws) | (p, ws) <- zip chosen buckets ]

genWorkItems :: Gen [WorkItem]
genWorkItems = do
  ids <- sublistOf ([1..6] :: [Word8])
  shards <- vectorOf (length ids) (elements [0,1])
  pure [ mkItem n s | (n, s) <- zip ids shards ]

mkItem :: Word8 -> Word32 -> WorkItem
mkItem n shard =
  let cell = Cell shard 0 1 (-10) 10 0
      wid = BS.replicate 32 n
      instr = mkInstrStream (fromIntegral n)
  in WorkItem wid cell maxBound (fromIntegral n) 1 instr

mkInstrStream :: Int -> BS.ByteString
mkInstrStream _n =
  let instr = BS.pack [1,0,0,0,0,0,0,0]
      stream = BS.pack [1,0,0,0,8,0,0,0] <> instr
  in stream

bucketItems :: Int -> [WorkItem] -> [Int] -> [[WorkItem]]
bucketItems n items assigns =
  let emptyBuckets = replicate n []
  in foldl insert emptyBuckets (zip items assigns)
  where
    insert buckets (item, idx) =
      let (pre, b:post) = splitAt idx buckets
      in pre ++ (item:b) : post
