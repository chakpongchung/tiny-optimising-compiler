\begin{code}
module ProgramToIR where
import Language
import IR
import BaseIR
import qualified OrderedMap as M
import Data.Traversable
import Data.Foldable
import Control.Monad.State.Strict
import qualified Data.Tree as T
import PrettyUtils
import Data.Text.Prettyprint.Doc as PP

data Builder = Builder {
  -- | The first BB that is present in the module
  entryBBId :: IRBBId,
 -- | The BB the builder is currently focused on
  currentBBId :: IRBBId,
  -- | Mapping from BBId to IRBB
  bbIdToBB :: M.OrderedMap IRBBId IRBB,
  -- | counter to generate new instruction name
  tmpInstNamesCounter :: Int,
  -- | Map from name to count of number of times name has occured
  instNameCounter :: M.OrderedMap String Int,
  -- | Map from literal name to Value
  literalToValue :: M.OrderedMap Literal Value
}

-- | Create a new builder with an empty basic block
newBuilder :: Builder
newBuilder =
  execState mkDefaultBB initbuilder
    where
      mkDefaultBB = do
        bbid <- createNewBB (Label "default")
        focusBB bbid
        -- Set the "entry" basic block so we can later give it to IRProgram
        modify (\b -> b { entryBBId = bbid })

      initbuilder = (Builder {
        entryBBId = Label "",
        currentBBId = Label "",
        bbIdToBB = mempty,
        tmpInstNamesCounter=0,
        instNameCounter=mempty,
        literalToValue=mempty
    })

-- | Get the current Basic block ID
getCurrentBBId :: State Builder IRBBId
getCurrentBBId = gets currentBBId

-- | Focus the basic block given by the ID
focusBB :: IRBBId -> State Builder ()
focusBB id = modify (\b-> b { currentBBId=id })

-- | Append a new basic block. DOES NOT switch the currentBBId to the new basic block. For that, see focusBB
createNewBB :: Label Builder -> State Builder IRBBId
createNewBB name = do
  idtobbs <- gets bbIdToBB
  let nbbs = M.size idtobbs
  let nameunique = Label ((unLabel name) ++ "." ++ show nbbs)
  let newbb = defaultIRBB { bbLabel=nameunique }
  modify (\b -> b { bbIdToBB = M.insert nameunique newbb idtobbs  } )
  return nameunique


-- | Create a temporary instruction name.
getTempInstName :: State Builder (Label Inst)
getTempInstName = do
  n <- gets tmpInstNamesCounter
  modify (\b -> b { tmpInstNamesCounter=n+1 })
  return . Label $ "tmp." ++ show n

getUniqueInstName :: String -> State Builder (Label Inst)
getUniqueInstName s = do
    counts <- gets instNameCounter
    let instNameCounter' = M.insertWith (\_ old -> old + 1) s 0 counts
    modify (\b -> b {instNameCounter=instNameCounter' })

    let curcount = case M.lookup s instNameCounter' of
                        Just count -> count
                        Nothing -> error . docToString $ pretty "no count present for: " <+> pretty s
    if curcount == 0
    then return (Label s)
    else return (Label (s ++ "." ++ show curcount))



-- | Create a temporary name for a return instruction
-- | Note that we cheat in the implementation, by just "relabelling"
-- | an instruction label to a ret instruction label.
getTempRetInstName :: State Builder (Label RetInst)
getTempRetInstName = Label . unLabel <$> getTempInstName

-- | Add a mapping between literal and value.
mapLiteralToValue :: Literal -> Value -> State Builder ()
mapLiteralToValue l v = do
  ltov <- gets literalToValue
  -- TODO: check that we do not repeat literals.
  modify (\b -> b { literalToValue=M.insert l v ltov })
  return ()

-- | Get the value that the Literal maps to.
getLiteralValueMapping :: Literal -> State Builder Value
getLiteralValueMapping lit = do
  ltov <- gets literalToValue
  return $ ltov M.! lit

-- | lift an edit of a basic block to the current basic block focused
-- | in the Builder.
liftBBEdit :: (IRBB -> IRBB) -> Builder -> Builder
liftBBEdit f builder = builder {
    bbIdToBB = M.adjust f (currentBBId builder) (bbIdToBB builder)
}

-- | Set the builder's current basic block to the i'th basic block
setBB :: Builder -> IRBBId -> Builder
setBB builder i = builder {
  currentBBId = i
}


-- | Append instruction "I" to the builder
appendInst :: Named Inst -> State Builder Value
appendInst i = do
  modify . liftBBEdit $ (appendInstToBB i)
  return $ ValueInstRef (namedName i)
  where
    appendInstToBB :: Named Inst -> IRBB -> IRBB
    appendInstToBB i bb = bb { bbInsts=bbInsts bb ++ [i] }

setRetInst :: RetInst -> State Builder ()
setRetInst i = do
  modify . liftBBEdit $ (setBBRetInst i)
  where
    setBBRetInst :: RetInst -> IRBB -> IRBB
    setBBRetInst i bb = bb { bbRetInst=i }


mkBinOpInst :: Value -> BinOp ->  Value -> Inst
mkBinOpInst lhs Plus rhs = InstAdd lhs rhs
mkBinOpInst lhs Multiply rhs = InstMul lhs rhs
mkBinOpInst lhs L rhs = InstL lhs rhs
mkBinOpInst lhs And rhs = InstAnd lhs rhs

buildExpr :: Expr' -> State Builder Value
buildExpr (EInt _ i) = return $  ValueConstInt i
buildExpr (ELiteral _ lit) = do
    name <- getUniqueInstName $ unLiteral lit ++ ".load"
    val <- getLiteralValueMapping lit
    appendInst $ name =:=  InstLoad val

buildExpr (EBinOp _ lhs op rhs) = do
    lhs <- buildExpr lhs
    rhs <- buildExpr rhs
    let inst = (mkBinOpInst lhs op rhs)
    name <- getTempInstName
    -- TODO: generate fresh labels
    appendInst $ name =:= inst

-- | Build the IR for the assignment, and return a reference to @InstStore
-- | TODO: technically, store should not return a Value
buildAssign :: Literal -> Expr' -> State Builder Value
buildAssign lit expr = do
  exprval <- buildExpr expr
  litval <- getLiteralValueMapping lit
  name <- getUniqueInstName $ "_"
  -- TODO: do not allow Store to be named with type system trickery
  appendInst $ name =:= InstStore litval exprval
  return $ ValueInstRef name

-- | Build IR for "define x"
buildDefine :: Literal -> State Builder Value
buildDefine lit = do
  name <- getUniqueInstName . unLiteral $ lit
  mapLiteralToValue lit (ValueInstRef name)
  appendInst $ name =:= InstAlloc

-- | Build IR for "Return"
buildRet :: Expr' -> State Builder ()
buildRet retexpr = do
  retval <- buildExpr retexpr
  setRetInst $ RetInstRet retval

-- | Build IR for "Stmt"
buildStmt :: Stmt' -> State Builder ()
buildStmt (Define _ lit) = buildDefine lit >> return ()
buildStmt (Assign _ lit expr) = buildAssign lit expr >> return ()
buildStmt (If _ cond then' else') = do
  condval <- buildExpr cond
  currbb <- getCurrentBBId


  bbthen <- createNewBB (Label "then")
  focusBB bbthen
  stmtsToInsts then'

  bbelse <- createNewBB (Label "else")
  focusBB bbelse
  stmtsToInsts else'

  bbjoin <- createNewBB (Label "join")
  focusBB bbthen
  setRetInst $ RetInstBranch bbjoin

  focusBB bbelse
  setRetInst $ RetInstBranch bbjoin

  focusBB currbb
  setRetInst $ RetInstConditionalBranch condval bbthen bbelse

  focusBB bbjoin

buildStmt (While _ cond body) = do
  curbb <- getCurrentBBId
  condbb <- createNewBB (Label "while.cond")
  bodybb <- createNewBB (Label "while.body")
  endbb <- createNewBB (Label "while.end")

  focusBB condbb
  condval <- buildExpr cond
  setRetInst $ RetInstConditionalBranch condval bodybb endbb

  focusBB bodybb
  stmtsToInsts body
  setRetInst $ RetInstBranch condbb

  focusBB curbb
  setRetInst $ RetInstBranch condbb

  focusBB endbb

buildStmt (Return _ retexpr) = buildRet retexpr

-- Given a collection of statements, create a State that will create these
-- statements in the builder
stmtsToInsts :: [Stmt'] -> State Builder ()
stmtsToInsts stmts = (for_ stmts buildStmt)


programToIR :: Program' -> IRProgram
programToIR (Language.Program stmts) =
  BaseIR.Program {
    programBBMap = bbIdToBB  builder,
    programEntryBBId = entryBBId builder
  } where
      builder = execState (stmtsToInsts stmts) newBuilder
\end{code}
