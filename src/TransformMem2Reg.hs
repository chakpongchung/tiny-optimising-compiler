{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
module TransformMem2Reg(constructDominatorTree,
    CFG(..),
    mkBBGraph,
    constructBBDominators,
    getAllChildren,
    getDominanceFrontier) where

import IR
import Data.Tree
import Data.List(nub)
import qualified Data.Set as S
import qualified Data.Map as M
import Data.Text.Prettyprint.Doc as PP
import Debug.Trace
import PrettyUtils
import Control.Monad.Reader
import Data.Traversable
import qualified Data.Monoid as Monoid
import qualified Data.Set as S
import qualified Data.List.NonEmpty as NE

-- | Represents a graph with `a` as a vertex ID type
newtype Graph a = Graph { edges :: [(a, a)] }

-- | The control flow graph, which is a graph of basic blocks
type CFG = Graph BBId

instance Pretty a => Pretty (Graph a) where
  pretty graph =
    vcat [pretty "BB graph edges",
          (vcat . map (indent 4 . pretty) . edges $ graph)]

-- | return predecessors of a node
getPredecessors :: Eq a => Graph a -> a -> [a]
getPredecessors g bbid = [ src | (src, sink) <- (edges g), sink == bbid]

-- | Returns the children of an element in a dom tree
-- | This returns only the immediate children.
getImmediateChildren :: Eq a => Graph a -> a -> [a]
getImmediateChildren (Graph edges) a = [dest | (src, dest) <- edges, src==a]

-- | Return all the vertices of the subgraph
getAllChildren :: Eq a => Graph a -> a -> [a]
getAllChildren tree@(Graph edges) a =
  a:(curChilds >>= (getAllChildren tree)) where
  curChilds = getImmediateChildren tree a

-- | Return the set of vertices in DomTree
vertices :: Eq a => Graph a  -> [a]
vertices (Graph edges) = nub (map fst edges ++ map snd edges)

-- | Get the successors of this basic block
getBBSuccessors :: BasicBlock -> [BBId]
getBBSuccessors (BasicBlock { bbRetInst = RetInstTerminal}) = []
getBBSuccessors (BasicBlock { bbRetInst = RetInstBranch next}) = [next]
getBBSuccessors (BasicBlock { bbRetInst = RetInstConditionalBranch _ l r}) = [l, r]

mkBBGraph :: M.Map BBId BasicBlock -> CFG
mkBBGraph bbMap = Graph (M.foldMapWithKey makeEdges bbMap)  where

    -- Make the edges corresponding to basic block.
    makeEdges :: BBId -> BasicBlock -> [(BBId, BBId)]
    makeEdges bbid bb = map (\succ -> (bbid, succ)) (getBBSuccessors bb)

-- a dominator tree is a tree of basic blocks
newtype DominatorTree  = Tree BasicBlock

-- BBId of the root node.
type EntryBBId = BBId


-- | Set of nodes that dominate a node.
type DomSet =  S.Set BBId

instance Pretty a => Pretty (S.Set a) where
  pretty = pretty . S.toList

instance (Pretty k, Pretty v) => Pretty (M.Map k v) where
  pretty m = vsep ( map (\(k, v) -> pretty k <+> pretty ":" <+> pretty v) (M.toList m))

-- | Map from a node to the set of nodes that dominate it
type BBIdToDomSet = M.Map BBId DomSet


initialBBIdToDomSet :: EntryBBId ->  -- ^entry BB ID
                  [BBId] ->  -- ^All BB IDs
                  BBIdToDomSet
initialBBIdToDomSet entryid ids = M.fromList (mapEntry:mapAllExceptEntry) where
  -- entry block only dominantes itself
  mapEntry :: (BBId, DomSet)
  mapEntry = (entryid, S.fromList [entryid])
  -- IDs other than the entry block
  nonEntryIds :: [BBId]
  nonEntryIds = filter (/= entryid) ids
  -- list mapping basic block Ids to dominance sets
  mapAllExceptEntry ::  [(BBId, DomSet)]
  mapAllExceptEntry =  zip nonEntryIds (repeat allDomSet)
  -- all nodes in the dom set
  allDomSet :: DomSet
  allDomSet = S.fromList ids



-- Get the predecessors of 'BBId' in 'Graph'

dominfoIterate :: EntryBBId -> -- ^Entry node ID
                 CFG -> -- ^Graph of BBs
                 BBIdToDomSet -> -- ^Previous dom info
                 BBIdToDomSet -- ^ New dom info
dominfoIterate entryid cfg prevdominfo =  M.mapWithKey computeNewDom prevdominfo where
  -- For the root node, DomSet_iplus1(root) = root
  -- For a non-root node, DomSet_iplus1(n) = intersect (forall p \in preds(n) DomSet_i(p)) U {n}
  computeNewDom :: BBId -> DomSet -> DomSet
  computeNewDom id old = if id == entryid then old else computeNewNonRootDom id
  -- compute the dom set of a node that is not the root
  computeNewNonRootDom :: BBId -> DomSet
  computeNewNonRootDom bbid = (combinePredDomSets ((getDoms . preds) bbid)) `S.union` (S.singleton bbid)

  -- predecessors of id
  preds :: BBId -> [BBId]
  preds bbid = getPredecessors cfg bbid

  -- combine all predecessor dom sets by intersecting them
  combinePredDomSets :: [DomSet] -> DomSet
  combinePredDomSets [] = error "unreachable node in domset"
  combinePredDomSets ds = foldl1 S.intersection ds

  -- get dominators of ids
  getDoms :: [BBId] -> [DomSet]
  getDoms bbids = map (prevdominfo M.!) bbids

getFirstAdjacentEqual :: Eq a => [a] -> a
getFirstAdjacentEqual as = fst . head $ dropWhile (\(a, a') -> a /= a') (zip as (tail as))

-- Map each basic block to the set of basic blocks that dominates it
constructBBDominators :: IRProgram -> BBIdToDomSet
constructBBDominators program = getFirstAdjacentEqual iterations where
    -- iterations of domInfoIterate applied
    iterations :: [BBIdToDomSet]
    iterations = iterate (dominfoIterate entryid cfg) initdominfo

    -- graph structure
    cfg :: CFG
    cfg =  mkBBGraph (irProgramBBMap program)

    -- seed constructBBDominators
    initdominfo :: BBIdToDomSet
    initdominfo = initialBBIdToDomSet entryid bbids

    -- ID of the root node
    entryid :: BBId
    entryid = irProgramEntryBBId program

    -- list of all basic block IDs
    bbids :: [BBId]
    bbids = M.keys (irProgramBBMap program)


data DomTreeContext = DomTreeContext {
  ctxBBIdToDomSet :: BBIdToDomSet,
  ctxEntryId :: EntryBBId
}

-- | Returns the dominators of BBId
getBBDominators :: BBId -> Reader DomTreeContext DomSet
getBBDominators bbid = do
  bbIdToDomSet <- reader ctxBBIdToDomSet
  return $ bbIdToDomSet M.! bbid

-- | Returns the struct dominators of BBId
getBBStrictDominators :: BBId -> Reader DomTreeContext DomSet
getBBStrictDominators bbid = S.filter (/= bbid) <$> (getBBDominators bbid)


-- | Returns whether y dominates x
doesDominate :: BBId -> BBId -> Reader DomTreeContext Bool
doesDominate x y = do
    bbIdToDomSet <- reader ctxBBIdToDomSet
    return $ x `S.member` (bbIdToDomSet M.! y)

-- | Run a forall in a traversable for a monadic context
allTraversable :: (Foldable t, Traversable t, Monad m) => t a -> (a -> m Bool) -> m Bool
allTraversable ta mpred = (foldl (&&) True) <$> (forM ta mpred)

-- | Return if the BBId is dominated by all bbs *other than itself* in others
isDominatedByAllOthers :: [BBId] -> BBId -> Reader DomTreeContext Bool
isDominatedByAllOthers others self =
  allTraversable others(\other -> if other == self then return True
                                                    else doesDominate other self)

-- | Returns the immediate dominator if present, otherwise returns Nothing
getImmediateDominator :: BBId -> Reader DomTreeContext (Maybe BBId)
getImmediateDominator bbid = do
    entryid <- reader ctxEntryId
    if entryid == bbid then
      return Nothing
    else do
            strictDoms <- S.toList <$> getBBStrictDominators bbid
            idoms <-  filterM (isDominatedByAllOthers strictDoms) strictDoms
            case idoms of
                    [idom] -> return (Just idom)
                    [] -> return Nothing
                    _ -> error $ "*** found more than one idom:\n" ++ show (prettyableToString idoms)


foldMapM :: (Foldable t, Monad m, Monoid r) => t a -> (a -> m r) -> m r
foldMapM ta mfn = foldM (\monoid a -> (monoid Monoid.<>) <$> (mfn a)) mempty ta

-- newtype DomTree = DomTree { domTreeEdges :: [(BBId, BBId)] }
type DomTree = Graph BBId

-- | internal reader that is not exported
createDominatorTree_ :: Reader DomTreeContext DomTree
createDominatorTree_ = do
  bbs <- reader (M.keys . ctxBBIdToDomSet)
  idoms <- foldMapM bbs (\bb -> do
                              mIdom <- getImmediateDominator bb
                              case mIdom of
                                Just idom -> return [(idom, bb)]
                                Nothing -> return [])
  return $ Graph idoms




-- | Construct the Dominator tree from the dominator sets and the entry BB
constructDominatorTree :: M.Map BBId DomSet -> EntryBBId -> DomTree
constructDominatorTree bbidToDomSet entrybb  = runReader createDominatorTree_ (DomTreeContext bbidToDomSet entrybb)




-- | The `dominates` relation. Given two BB Ids, returns whether `a` dominates `b`
dominates :: DomTree -> BBId -> BBId -> Bool
dominates tree a b = b `elem` (getAllChildren tree a)

-- | Strictly dominates relation. `A` strictlyDom `B` iff `A` Dom `B` and `A` /= `B`
strictlyDominates :: DomTree -> BBId -> BBId -> Bool
strictlyDominates domtree a b = dominates domtree a b && a /= b

-- | Get the list of dominance frontiers of a given BB
-- | "The dominance frontier of a node d is the set of all nodes n such that d
-- |  dominates an immediate predecessor of n, but d does not strictly dominate
-- |  n. It is the set of nodes where d's dominance stops."
-- | TODO: think anbout why *an immediate preceseeor*, not *all immediate ...*.
getDominanceFrontier :: DomTree -> CFG -> BBId -> [BBId]
getDominanceFrontier tree@(Graph domedges) cfg cur =
  [bb | bb <- vertices tree, any (dominates tree cur) (preds bb) , not (strictlyDominates tree cur bb)] where
  preds bb = (getPredecessors cfg bb)


-- Get the names of all values allocated in a basic block
getBBAllocs :: BasicBlock -> [Label Inst]
getBBAllocs (BasicBlock{bbInsts=bbInsts}) =
  bbInsts >>= \(Named name inst) -> case inst of
                                        InstAlloc -> [name]
                                        _ -> []

-- | Adjust possibly many keys
adjustWithKeys :: Ord k => (k -> a -> a) -> [k] -> M.Map k a -> M.Map k a
adjustWithKeys f ks m = foldl (\m k -> M.adjustWithKey f k m) m ks

unsafeToNonEmpty :: [a] -> NE.NonEmpty a
unsafeToNonEmpty [] = error "unable to convert empty list to non empty"
unsafeToNonEmpty (x:xs) = x NE.:| xs

-- | For a given basic block, insert a phi node at the top
insertPhiNodeCallback_ :: CFG -> Label Inst -> BBId -> BasicBlock -> BasicBlock
insertPhiNodeCallback_ cfg lbl bbid bb@(BasicBlock{..}) =
    bb {bbInsts=bbInsts'} where
    bbInsts' :: [Named Inst]
    bbInsts' = (lbl =:= phi):bbInsts

    phi :: Inst
    phi = InstPhi . unsafeToNonEmpty $ (zip ((getPredecessors cfg bbid)) (repeat (ValueInstRef lbl)))


-- | Place Phi nodes for a given instruction at a set of start CFGs. Initially, they should be the
-- |  set of nodes that store to the original value
placePhiNodesForAlloc_ :: Label Inst -- ^Name of the original value
                          -> S.Set BBId -- ^BBs to process
                          -> S.Set BBId -- ^BBs to be processed
                          -> CFG -- ^The CFG of the function
                          -> DomTree -- ^The dominator tree of the function
                          -> M.Map BBId BasicBlock -- ^Function body
                          -> M.Map BBId BasicBlock
placePhiNodesForAlloc_ name curbbs processed cfg domtree bbmap =
    if null (curbbs)
    then bbmap
    else placePhiNodesForAlloc_ name curbbs' processed' cfg domtree bbmap'  where
            cur :: BBId
            cur = S.elemAt 0 curbbs

            -- | For every basic block in the dominance frontier, insert a phi node.
            bbmap' :: M.Map BBId BasicBlock
            bbmap' = adjustWithKeys (insertPhiNodeCallback_ cfg name) curfrontier bbmap

            curbbs' :: S.Set BBId
            curbbs' = ((S.deleteAt 0 curbbs) `S.union` (S.fromList curfrontier S.\\ processed'))

            curfrontier ::  [BBId]
            curfrontier = getDominanceFrontier domtree cfg cur

            processed' :: S.Set BBId
            processed' = (S.insert cur processed)

mapReverse :: (Ord k, Ord a) => M.Map k [a] -> M.Map a [k]
mapReverse m = M.fromListWith (++) [(a, [k]) | (k, as) <- M.toList m, a <- as]

-- References: http://www.cs.is.noda.tus.ac.jp/~mune/keio/m/ssa2.pdf
placePhiNodes_ :: CFG -> DomTree -> M.Map BBId BasicBlock -> M.Map BBId BasicBlock
placePhiNodes_ cfg domtree bbmap' = undefined where
  bbIdToAllocNames :: M.Map BBId [Label Inst]
  bbIdToAllocNames = fmap getBBAllocs bbmap'

  allocNamesToBBs :: M.Map (Label Inst) [BBId]
  allocNamesToBBs = undefined




transformMem2Reg :: IRProgram -> IRProgram
transformMem2Reg program@IRProgram{irProgramBBMap=bbmap,
                           irProgramEntryBBId=entrybbid} =
  IRProgram {irProgramBBMap=bbmap', irProgramEntryBBId=entrybbid} where
  cfg :: CFG
  cfg =  mkBBGraph bbmap

  bbIdToDomSet :: BBIdToDomSet
  bbIdToDomSet = constructBBDominators program

  domtree :: DomTree
  domtree = constructDominatorTree bbIdToDomSet entrybbid

  bbmap' = placePhiNodes_ cfg domtree bbmap'

