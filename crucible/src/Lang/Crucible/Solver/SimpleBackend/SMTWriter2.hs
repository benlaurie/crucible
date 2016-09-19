------------------------------------------------------------------------
-- |
-- Module      : Lang.Crucible.Solver.SimpleBackend.SMTWriter
-- Description : Definition of the simulator monad
-- Copyright   : (c) Galois, Inc 2014-15.
-- Maintainer  : Joe Hendrix <jhendrix@galois.com>
-- Stability   : provisional
--
-- This defines common definitions used in writing SMTLIB (2.0 and later), and
-- yices outputs from 'Elt' values.
--
-- The writer is designed to support solvers with arithmetic, propositional
-- logic, bitvector, tuples (aka. structs), and arrays.
--
-- It maps complex Elt values to either structs or arrays depending
-- on what the solver supports (structs are preferred if both are supported).
--
-- It maps multi-dimensional arrays to either arrays with structs as indices
-- if structs are supported or nested arrays if they are not.
--
-- The solver should detect when something is not supported and give an
-- error rather than sending invalid output to a file.
------------------------------------------------------------------------
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wwarn #-}
module Lang.Crucible.Solver.SimpleBackend.SMTWriter
  ( -- * Type classes
    SupportTermOps(..)
  , SMTWriter(..)
    -- * Terms
  , Term(..)
  , term_app
  , bin_app
  , app
  , app_list
  , builder_list
  , fromText
    -- * SMTWriter
  , WriterConn( supportFunctionDefs
              , supportFunctionArguments
              , supportQuantifiers
              )
  , connState
  , newWriterConn
  , pushEntryStack
  , popEntryStack
  , Command(..)
  , addCommand
  , mkFreeVar
  , SMT_Type(..)
  , freshBoundVarName
  , assumeFormula
    -- * SMTWriter operations
  , assume
  , mkFormula
  , SMTEvalFunctions(..)
  , smtExprGroundEvalFn
  ) where

import           Control.Exception
import           Control.Lens hiding ((.>))
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.ST
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Maybe
import qualified Data.Bimap as Bimap
import           Data.IORef
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Monoid
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.HashTable as PH
import           Data.Parameterized.Nonce (Nonce)
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableFC
import           Data.Ratio
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Text.Lazy.Builder (Builder)
import qualified Data.Text.Lazy.Builder as Builder
import qualified Data.Text.Lazy.Builder.Int as Builder (decimal)
import qualified Data.Text.Lazy as Lazy
import qualified Data.Text.Lazy.IO as Lazy
import           Data.Word
import           System.IO
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (<>))

import           Lang.Crucible.BaseTypes
import           Lang.Crucible.MATLAB.Intrinsics.Solver
import           Lang.Crucible.ProgramLoc
import qualified Lang.Crucible.Solver.Interface as I
  ( ArrayResultWrapper(..)
  , IndexLit(..)
  , IsPred(..)
  , IsExpr(..)
  , IsBoolExprBuilder(..)
  , IsExprBuilder(..)
  )
import           Lang.Crucible.Solver.SimpleBackend.GroundEval
import           Lang.Crucible.Solver.SimpleBackend.ProblemFeatures
import           Lang.Crucible.Solver.SimpleBuilder
import           Lang.Crucible.Solver.Symbol
import qualified Lang.Crucible.Solver.WeightedSum as WSum
import           Lang.Crucible.Utils.Complex
import qualified Lang.Crucible.Utils.Hashable as Hash
import qualified Lang.Crucible.Utils.UnaryBV as UnaryBV

------------------------------------------------------------------------
-- Term construction typeclasses

infixr 3 .&&
infixr 2 .||
infix 4 .==
infix 4 ./=
infix 4 .>
infix 4 .>=
infix 4 .<
infix 4 .<=

-- | 'TypeMap' defines how a given 'BaseType' maps to an SMTLIB type.
--
-- It is necessary as there may be several ways in which a base type can
-- be encoded.
data TypeMap (tp::BaseType) where
  BoolTypeMap    :: TypeMap BaseBoolType
  NatTypeMap     :: TypeMap BaseNatType
  IntegerTypeMap :: TypeMap BaseIntegerType
  RealTypeMap    :: TypeMap BaseRealType
  BVTypeMap      :: (1 <= w) => !(NatRepr w) -> TypeMap (BaseBVType w)
  -- A complex number mapped to an SMTLIB struct.
  ComplexToStructTypeMap :: TypeMap BaseComplexType
  -- A complex number mapped to an SMTLIB array from boolean to real.
  ComplexToArrayTypeMap  :: TypeMap BaseComplexType

  -- An array that is encoded using a builtin SMT theory of arrays.
  --
  -- This theory typically restricts the set of arrays that can be encoded,
  -- but have a decidable equality.
  PrimArrayTypeMap :: !(Ctx.Assignment TypeMap (idxl Ctx.::> idx))
                   -> !(TypeMap tp)
                   -> TypeMap (BaseArrayType (idxl Ctx.::> idx) tp)

  -- An array that is encoded as an SMTLIB function.
  --
  -- The element type must not be an array encoded as a function.
  FnArrayTypeMap :: !(Ctx.Assignment TypeMap (idxl Ctx.::> idx))
                 -> TypeMap tp
                 -> TypeMap (BaseArrayType (idxl Ctx.::> idx) tp)

  -- A struct encoded as an SMTLIB struct/ yices tuple.
  --
  -- None of the fields should be arrays encoded as functions.
  StructTypeMap :: !(Ctx.Assignment TypeMap idx)
                -> TypeMap (BaseStructType idx)

instance Eq (TypeMap tp) where
  x == y = isJust (testEquality x y)

instance TestEquality TypeMap where
  testEquality BoolTypeMap BoolTypeMap = Just Refl
  testEquality NatTypeMap NatTypeMap = Just Refl
  testEquality IntegerTypeMap IntegerTypeMap = Just Refl
  testEquality RealTypeMap RealTypeMap = Just Refl
  testEquality (BVTypeMap x) (BVTypeMap y) = do
    Refl <- testEquality x y
    return Refl
  testEquality ComplexToStructTypeMap ComplexToStructTypeMap =
    Just Refl
  testEquality ComplexToArrayTypeMap ComplexToArrayTypeMap =
    Just Refl
  testEquality (PrimArrayTypeMap xa xr) (PrimArrayTypeMap ya yr) = do
    Refl <- testEquality xa ya
    Refl <- testEquality xr yr
    Just Refl
  testEquality (FnArrayTypeMap xa xr) (FnArrayTypeMap ya yr) = do
    Refl <- testEquality xa ya
    Refl <- testEquality xr yr
    Just Refl
  testEquality (StructTypeMap x) (StructTypeMap y) = do
    Refl <- testEquality x y
    Just Refl
  testEquality _ _ = Nothing

asBaseType :: TypeMap tp -> BaseTypeRepr tp
asBaseType tm =
  case tm of
    BoolTypeMap -> BaseBoolRepr
    NatTypeMap -> BaseNatRepr
    IntegerTypeMap -> BaseIntegerRepr
    RealTypeMap -> BaseRealRepr
    BVTypeMap w -> BaseBVRepr w
    ComplexToStructTypeMap -> BaseComplexRepr
    ComplexToArrayTypeMap -> BaseComplexRepr
    PrimArrayTypeMap a r -> BaseArrayRepr (fmapFC asBaseType a) (asBaseType r)
    FnArrayTypeMap a r -> BaseArrayRepr (fmapFC asBaseType a) (asBaseType r)
    StructTypeMap f -> BaseStructRepr (fmapFC asBaseType f)

-- | Return the SMT_Type underlying a TypeMap.
asSMTType :: TypeMap tp -> SMT_Type
asSMTType BoolTypeMap    = SMT_BoolType
asSMTType NatTypeMap     = SMT_IntegerType
asSMTType IntegerTypeMap = SMT_IntegerType
asSMTType RealTypeMap    = SMT_RealType
asSMTType (BVTypeMap w) = SMT_BVType (natValue w)
asSMTType ComplexToStructTypeMap = SMT_StructType [ SMT_RealType, SMT_RealType ]
asSMTType ComplexToArrayTypeMap  = SMT_ArrayType [SMT_BoolType] SMT_RealType
asSMTType (PrimArrayTypeMap i r) =
  SMT_ArrayType (toListFC asSMTType i) (asSMTType r)
asSMTType (FnArrayTypeMap i r) =
  SMT_FnType (toListFC asSMTType i) (asSMTType r)
asSMTType (StructTypeMap f) = SMT_StructType (toListFC asSMTType f)

data SMT_Type
   = SMT_BoolType
   | SMT_BVType Integer
   | SMT_IntegerType
   | SMT_RealType
   | SMT_ArrayType [SMT_Type] SMT_Type
   | SMT_StructType [SMT_Type]
     -- | A function type.
   | SMT_FnType [SMT_Type] SMT_Type
  deriving (Eq, Ord)

data BaseTypeError = ComplexTypeUnsupported
                   | ArrayUnsupported

type ArrayConstantFn v
   = [SMT_Type]
     -- ^ Type for indices
     -> SMT_Type
     -- ^ Type for value.
     -> v
     -- ^ Constant to assign all values.
     -> v

-- | A class of values containing rational and operations.
class Num v => SupportTermOps v where
  boolExpr :: Bool -> v

  notExpr  :: v -> v

  andAll :: [v] -> v
  orAll :: [v] -> v

  (.&&)    :: v -> v -> v
  x .&& y = andAll [x, y]

  (.||)    :: v -> v -> v
  x .|| y = orAll [x, y]

  -- | Compare two elements for equality.
  (.==)  :: v -> v -> v

  -- | Compare two elements for in-equality.
  (./=) :: v -> v -> v
  x ./= y = notExpr (x .== y)

  impliesExpr :: v -> v -> v
  impliesExpr x y = notExpr x .|| y

  -- | Create a forall expression
  forallExpr :: [(Text, SMT_Type)] -> v -> v

  -- | Create an exists expression
  existsExpr :: [(Text, SMT_Type)] -> v -> v

  -- | Create a let expression.
  letExpr :: [(Text, Term h)] -> v -> v

  -- | Create an if-then-else expression.
  ite :: v -> v -> v -> v

  -- | Add a list of values together.
  sumExpr :: [v] -> v
  sumExpr [] = 0
  sumExpr (h:r) = foldl (+) h r

  -- | Convert an integer expression to a real.
  termIntegerToReal :: v -> v

  -- | Convert an integer expression to a real.
  termRealToInteger :: v -> v

  -- | Convert a rational to a term.
  rationalTerm :: Rational -> v

  -- | Less-then-or-equal
  (.<=) :: v -> v -> v

  -- | Less-then
  (.<)  :: v -> v -> v
  x .< y = notExpr (y .<= x)

  -- | Greater then
  (.>)  :: v -> v -> v
  x .> y = y .< x

  -- | Greater then or equal
  (.>=) :: v -> v -> v
  x .>= y = y .<= x

  -- | Create expression from bitvector.
  bvTerm :: NatRepr w -> Integer -> v
  bvNeg :: v -> v
  bvAdd :: v -> v -> v
  bvSub :: v -> v -> v
  bvMul :: v -> v -> v

  bvSLe :: v -> v -> v
  bvULe :: v -> v -> v

  bvSLt :: v -> v -> v
  bvULt :: v -> v -> v

  bvUDiv :: v -> v -> v
  bvURem :: v -> v -> v
  bvSDiv :: v -> v -> v
  bvSRem :: v -> v -> v

  bvAnd :: v -> v -> v
  bvOr  :: v -> v -> v
  bvXor :: v -> v -> v
  bvNot :: v -> v

  bvShl  :: v -> v -> v
  bvLshr :: v -> v -> v
  bvAshr :: v -> v -> v

  -- | Concatenate two bitvectors together.
  bvConcat :: v -> v -> v

  -- | @bvExtract w i n v@ extracts bits [i..i+n) from @v@ as a new
  -- bitvector.   @v@ must contain at least @w@ elements, and @i+n@
  -- must be less than or equal to @w@.  The result has @n@ elements.
  -- The least significant bit of @v@ should have index @0@.
  bvExtract :: NatRepr w -> Integer -> Integer -> v -> v

  -- | @bvTestBit w i x@ returns predicate that holds if bit @i@
  -- in @x@ is set to true.  @w@ should be the number of bits in @x@.
  bvTestBit :: NatRepr w -> Integer -> v -> v
  bvTestBit w i x = (bvExtract w i 1 x .== bvTerm w1 1)
    where w1 :: NatRepr 1
          w1 = knownNat

  -- | 'arrayUpdate a i v' returns an array that contains value 'v' at
  -- index 'i', and the same value as in 'a' at every other index.
  arrayUpdate :: v -> [v] -> v -> v

  -- | Select an element from an array
  arraySelect :: v -> [v] -> v

  -- | Create a struct with the given fields.
  structCtor :: [v] -- ^ Fields to struct
             -> v

  -- | Select a field from a struct.
  --
  -- The first argument contains the type of the fields of the struct.
  -- The second argument contains the stuct value.
  -- The third argument defines the index.
  structFieldSelect :: Int -- ^ Number of struct fields.
                    -> v
                    -> Int -- ^ 0-based index of field.
                    -> v

  -- | Create a constant array
  --
  -- This may return Nothing if the solver does not support constant arrays.
  arrayConstant :: Maybe (ArrayConstantFn v)
  arrayConstant = Nothing

  -- | Predicate that holds if a real number is an integer.
  realIsInteger :: v -> v

  realSin :: v -> v

  realCos :: v -> v

  realATan2 :: v -> v -> v

  realSinh :: v -> v

  realCosh :: v -> v

  realExp  :: v -> v

  realLog  :: v -> v

  -- | Apply the arguments to the given function.
  smtFnApp :: v -> [v] -> v

  -- | Update a function value to return a new value at the given point.
  --
  -- This may be Nothing if solver has no builtin function for update.
  smtFnUpdate :: Maybe (v -> [v] -> v -> v)
  smtFnUpdate = Nothing

  -- | Function for creating a lambda term if output supports it.
  --
  -- Yices support lambda expressions, but SMTLIB2 does not.
  -- The function takes arguments and the expression.
  lambdaTerm :: Maybe ([(Text, SMT_Type)] -> v -> v)
  lambdaTerm = Nothing

------------------------------------------------------------------------
-- Term

structComplexRealPart :: SupportTermOps v => v -> v
structComplexRealPart c = structFieldSelect 2 c 0

structComplexImagPart :: SupportTermOps v => v -> v
structComplexImagPart c = structFieldSelect 2 c 1

arrayComplexRealPart :: SupportTermOps v => v -> v
arrayComplexRealPart c = arraySelect c [boolExpr False]

arrayComplexImagPart :: SupportTermOps v => v -> v
arrayComplexImagPart c = arraySelect c [boolExpr True]

-- | A term in the output language.
-- The parameter is a phantom parameter that is intended to enable clients to avoid
-- mixing terms from different languages.
newtype Term (h :: *) = T { renderTerm :: Builder }

app :: Builder -> [Builder] -> Builder
app o [] = o
app o args = app_list o args

app_list :: Builder -> [Builder] -> Builder
app_list o args = "(" <> o <> go args
  where go [] = ")"
        go (f:r) = " " <> f <> go r

builder_list :: [Builder] -> Builder
builder_list [] = "()"
builder_list (h:l) = app_list h l

term_app :: Builder -> [Term h] -> Term h
term_app o args = T (app o (renderTerm <$> args))

bin_app :: Builder -> Term h -> Term h -> Term h
bin_app o x y = term_app o [x,y]

------------------------------------------------------------------------
-- SMTExpr

-- | An expresion for the SMT solver together with information about its type.
data SMTExpr h (tp :: BaseType) where
  SMTName :: !(TypeMap tp) -> !Text -> SMTExpr h tp
  SMTExpr :: !(TypeMap tp) -> !(Term h) -> SMTExpr h tp

-- | Converts an SMT to a base expression.
asBase :: SupportTermOps (Term h)
       => SMTExpr h tp
       -> Term h
asBase (SMTName _ n) = fromText n
asBase (SMTExpr _ e) = e

smtExprType :: SMTExpr h tp -> TypeMap tp
smtExprType (SMTName tp _) = tp
smtExprType (SMTExpr tp _) = tp

------------------------------------------------------------------------
-- WriterState

-- | State for writer.
data WriterState = WriterState { _nextTermIdx :: !Word64
                               , _lastPosition :: !Position
                               , _position     :: !Position
                               }

-- | The next index to use in dynamically generating a variable name.
nextTermIdx :: Simple Lens WriterState Word64
nextTermIdx = lens _nextTermIdx (\s v -> s { _nextTermIdx = v })

-- | Last position written to file.
lastPosition :: Simple Lens WriterState Position
lastPosition = lens _lastPosition (\s v -> s { _lastPosition = v })

-- | Position written to file.
position :: Simple Lens WriterState Position
position = lens _position (\s v -> s { _position = v })

emptyState :: WriterState
emptyState = WriterState { _nextTermIdx     = 0
                         , _lastPosition = InternalPos
                         , _position     = InternalPos
                         }

-- | Create a new variable
--
-- Variable names have a prefix, an exclamation mark and a unique number.
-- The MSS system ensures that no
freshVarName :: State WriterState Text
freshVarName = freshVarName' "x!"

-- | Create a new variable
--
-- Variable names have a prefix, an exclamation mark and a unique number.
-- The MSS system ensures that no
freshVarName' :: Builder -> State WriterState Text
freshVarName' prefix = do
  n <- use nextTermIdx
  nextTermIdx += 1
  return $! (Lazy.toStrict $ Builder.toLazyText $ prefix <> Builder.decimal n)

------------------------------------------------------------------------
-- SMTWriter

fromText :: Text -> Term h
fromText t = T (Builder.fromText t)

data SMTSymFn ctx where
  SMTSymFn :: !Text
           -> !(Ctx.Assignment TypeMap args)
           -> !(TypeMap ret)
           -> SMTSymFn (args Ctx.::> ret)

-- The writer connection maintains a connection to the SMT solver.
--
-- It is responsible for knowing the capabilities of the solver; generating
-- fresh names when needed; maintaining the stack of pushes and pops, and
-- sending queries to the solver.
data WriterConn t (h :: *) =
  WriterConn { smtWriterName :: !String
               -- ^ Name of writer for error reporting purposes.
             , connHandle :: !Handle
               -- ^ Handle to write to
             , supportFunctionDefs :: !Bool
               -- ^ Indicates if the writer can define constants or functions in terms
               -- of an expression.
               --
               -- If this is not supported, we can only declare free variables, and
               -- assert that they are equal.
             , supportFunctionArguments :: !Bool
               -- ^ Functions may be passed as arguments to other functions.
               --
               -- We currently never allow SMT_FnType to appear in structs or array
               -- indices.
             , supportQuantifiers :: !Bool
               -- ^ Allow the SMT writer to generate problems with quantifiers.
             , supportedFeatures :: !ProblemFeatures
               -- ^ Indicates features supported by the solver.
             , smtFnCache :: !(PH.HashTable PH.RealWorld (Nonce t) SMTSymFn)
               -- ^ Allow the SMT writer to generate problems with quantifiers.
             , entryStack :: !(IORef [IdxCache t (SMTExpr h)])
               -- ^ A stack of hash tables, corresponding to the lexical scopes induced by
               --   frame push/pops.  The entire stack of tables is searched top-down when
               --   looking up element nonce values.  Elements that are to persist across
               --   pops are written through the entire stack.
             , stateRef :: !(IORef WriterState)
               -- ^ Reference to current state
             , varBindings :: !(SymbolVarBimap t)
               -- ^ Symbol variables.
             , connState :: !h
               -- ^ The specific connection information.
             }

-- | Push a new frame to the stack for maintaining the writer cache.
pushEntryStack :: WriterConn t h -> IO ()
pushEntryStack c = do
  h <- newIdxCache
  modifyIORef' (entryStack c) $ (h:)

popEntryStack :: WriterConn t h -> IO ()
popEntryStack c = do
  stk <- readIORef (entryStack c)
  case stk of
   []  -> fail "Could not pop from empty entry stack."
   [_] -> fail "Could not pop from empty entry stack."
   (_:r) -> writeIORef (entryStack c) r

newWriterConn :: Handle
              -> String
              -- ^ Name of solver for reporting purposes.
              -> ProblemFeatures
              -- ^ Indicates what features are supported by the solver.
              -> SymbolVarBimap t
              -- ^ A bijective mapping between variables and their
              -- canonical name (if any).
              -> cs
                 -- ^ State information specific to the type of connection
              -> IO (WriterConn t cs)
newWriterConn h solver_name features bindings cs = do
  fnCache   <- stToIO $ PH.new
  r <- newIORef emptyState
  c <- newIdxCache
  stk_ref <- newIORef [c]
  return $! WriterConn { smtWriterName = solver_name
                       , connHandle    = h
                       , supportFunctionDefs      = False
                       , supportFunctionArguments = False
                       , supportQuantifiers       = False
                       , supportedFeatures        = features
                       , smtFnCache   = fnCache
                       , entryStack   = stk_ref
                       , stateRef     = r
                       , varBindings  = bindings
                       , connState    = cs
                       }

cacheLookup :: WriterConn t h -> Nonce t tp -> IO (Maybe (SMTExpr h tp))
cacheLookup c n = go =<< readIORef (entryStack c)
 where go [] = return Nothing
       go (h:r) = do
           lookupIdx h n >>= \case
              Nothing -> go r
              Just x  -> return $ Just x

cacheValue :: WriterConn t h -> Nonce t tp -> TermLifetime -> SMTExpr h tp -> IO ()
cacheValue c n lifetime x = do
  stk <- readIORef (entryStack c)
  case stk of
     [] -> error "cacheValue: empty cache stack!"
     (h:r) -> do insertIdxValue h n x
                 case lifetime of
                    DeleteOnPop -> return ()
                    DeleteNever -> writethrough r
 where writethrough [] = return ()
       writethrough (h:r) = do insertIdxValue h n x
                               writethrough r

-- | Run state with handle.
withWriterState :: WriterConn t h -> State WriterState a -> IO a
withWriterState c m = do
  s0 <- readIORef (stateRef c)
  let (v,s) = runState m s0
  writeIORef (stateRef c) $! s
  return v

-- | Update the current program location to the given one.
updateProgramLoc :: WriterConn t h -> ProgramLoc -> IO ()
updateProgramLoc c l = withWriterState c $ position .= plSourceLoc l

newtype Command h = Cmd Builder

-- | Typeclass need to generate SMTLIB commands.
class (SupportTermOps (Term h)) => SMTWriter h where

  -- | Create a command that just defines a comment.
  commentCommand :: f h -> Builder -> Command h

  -- | Create a command that asserts a formula.
  assertCommand :: f h -> Term h -> Command h

  -- | Declare a new symbol with the given name, arguments types, and result type.
  declareCommand :: f h
                 -> Text
                 -> [SMT_Type]
                 -> SMT_Type
                 -> Command h

  -- | Define a new symbol with the given name, arguments, result type, and
  -- associated expression.
  --
  -- The argument contains the variable name and the type of the variable.
  defineCommand :: Text -- ^ Name of variable
                -> [(Text, SMT_Type)]
                -> SMT_Type
                -> Term h
                -> Command h

  -- | Declare a struct datatype if is has not been already given the number of
  -- arguments in the struct.
  declareStructDatatype :: WriterConn t h -> Int -> IO ()

-- | Write a command to the connection.
writeCommand :: WriterConn t h -> Command h -> IO ()
writeCommand conn (Cmd cmd) =
  Lazy.hPutStrLn (connHandle conn) (Builder.toLazyText cmd)

-- | Write a command to the connection along with position information
-- if it differs from the last position.
addCommand :: SMTWriter h => WriterConn t h -> Command h -> IO ()
addCommand conn cmd = do
  las <- withWriterState conn $ use lastPosition
  cur <- withWriterState conn $ use position

  -- If the position of the last command differs from the current position, then
  -- write the current position and update the last position.
  when (las /= cur) $ do
    writeCommand conn $ commentCommand conn $ buildPosition cur
    withWriterState conn $ lastPosition .= cur

  writeCommand conn cmd
  hFlush (connHandle conn)

-- | Create a new variable with the given name.
mkFreeVar :: SMTWriter h
          => WriterConn t h
          -> [SMT_Type]
          -> SMT_Type
          -> IO Text
mkFreeVar conn arg_types return_type = do
  var <- withWriterState conn $ freshVarName
  addCommand conn $ declareCommand conn var arg_types return_type
  return var

-- | Assume that the given formula holds.
assumeFormula :: SMTWriter h => WriterConn t h -> Term h -> IO ()
assumeFormula c p = addCommand c (assertCommand c p)

-- | Create a variable name eqivalent to the given expression.
freshBoundVarName :: SMTWriter h
                  => WriterConn t h
                  -> [(Text, SMT_Type)]
                     -- ^ Names of variables in term and associated type.
                  -> SMT_Type -- ^ Type of expression.
                  -> Term h
                  -> IO Text
freshBoundVarName conn args return_type expr = do
  var <- withWriterState conn $ freshVarName
  defineSMTVar conn var args return_type expr
  return var

-- | Create a variable name eqivalent to the given expression.
defineSMTVar :: SMTWriter h
             => WriterConn t h
             -> Text
                -- ^ Name of variable to define
                -- Should not be defined or declared in the current SMT context
             -> [(Text, SMT_Type)]
                -- ^ Names of variables in term and associated type.
             -> SMT_Type -- ^ Type of expression.
             -> Term h
             -> IO ()
defineSMTVar conn var args return_type expr
  | supportFunctionDefs conn = do
    addCommand conn $ defineCommand var args return_type expr
  | otherwise = do
    when (not (null args)) $ do
      fail $ smtWriterName conn ++ " interface does not support defined functions."
    addCommand conn $ declareCommand conn var [] return_type
    assumeFormula conn $ fromText var .== expr


-- | Function for create a new name given a base type.
data FreshVarFn h = FreshVarFn (forall tp . TypeMap tp -> IO (SMTExpr h tp))

-- | The state of a side collector monad
--
-- This has predicate for introducing new bound variables
data SMTCollectorState t h
  = SMTCollectorState
    { scConn :: !(WriterConn t h)
    , freshBoundTermFn :: !(Text -> [(Text, SMT_Type)] -> SMT_Type -> Term h -> IO ())
      -- ^ 'freshBoundTerm nm args ret_type ret' will record that 'nm(args) = ret'
      -- 'ret_type' should be the type of 'ret'.
    , freshConstantFn  :: !(Maybe (FreshVarFn h))
    , recordSideCondFn :: !(Maybe (Term h -> IO ()))
      -- ^ Called when we need to need to assert a predicate about some
      -- variables.
    }

-- | The SMT term collector
type SMTCollector t h = ReaderT (SMTCollectorState t h) IO

-- | Create a fresh constant
freshConstant :: SMTCollectorState t h
              -> String -- ^ The name of the constant based on its reaon.
              -> TypeMap tp -- ^ Type of the constant.
              -> IO (SMTExpr h tp)
freshConstant scs nm tpr = do
  case freshConstantFn scs of
   Nothing -> do
     loc <- withWriterState (scConn scs) $ use position
     fail $ "Cannot create the free constant within a function needed to define the "
       ++ nm ++ " term created at " ++ show loc ++ "."
   Just (FreshVarFn f) ->
     f tpr

-- | Given a solver connection and a base type repr, 'typeMap' attempts to
-- find the best encoding for a variable of that type supported by teh solver.
typeMap :: WriterConn t h  -> BaseTypeRepr tp -> Either BaseTypeError (TypeMap tp)
typeMap conn tp0 = do
  case typeMapNoFunction conn tp0 of
    Right tm -> Right tm
    -- Recover from array unsupported if possible.
    Left ArrayUnsupported
      | supportFunctionDefs conn
      , BaseArrayRepr idxTp eltTp <- tp0 ->
        FnArrayTypeMap <$> traverseFC (typeMapNoFunction conn) idxTp
                       <*> typeMapNoFunction conn eltTp
    -- Pass other functions on.
    Left e -> Left e

-- | This is a helper function for 'typeMap' that only returns values that can
-- be passed as arguments to a function.
typeMapNoFunction :: WriterConn t h -> BaseTypeRepr tp -> Either BaseTypeError (TypeMap tp)
typeMapNoFunction conn tp0 = do
  let feat = supportedFeatures conn
  case tp0 of
    BaseBoolRepr -> Right $! BoolTypeMap
    BaseBVRepr w -> Right $! BVTypeMap w
    BaseRealRepr -> Right $! RealTypeMap
    BaseNatRepr  -> Right $! NatTypeMap
    BaseIntegerRepr -> Right $! IntegerTypeMap
    BaseComplexRepr
      | feat `hasProblemFeature` useStructs        -> Right $! ComplexToStructTypeMap
      | feat `hasProblemFeature` useSymbolicArrays -> Right $! ComplexToArrayTypeMap
      | otherwise -> Left $! ComplexTypeUnsupported
    BaseArrayRepr idxTp eltTp -> do
      -- Check that solver supports primitive arrays, failing if not.
      unless (feat `hasProblemFeature` useSymbolicArrays) $ do
        Left $! ArrayUnsupported
      PrimArrayTypeMap <$> traverseFC (typeMapNoFunction conn) idxTp
                       <*> typeMapNoFunction conn eltTp
    BaseStructRepr flds ->
      StructTypeMap <$> traverseFC (typeMapNoFunction conn) flds

getBaseSMT_Type :: WriterConn t h -> SimpleBoundVar t tp -> IO (TypeMap tp)
getBaseSMT_Type conn v = do
  let nm = show (bvarName v)
  case typeMap conn (bvarType v) of
    Left ComplexTypeUnsupported -> do
      fail $ show $ text nm
        <+> text "is a complex variable, and we do not support this with"
        <+> text (smtWriterName conn ++ ".")
    Left ArrayUnsupported -> do
      fail $ show $ text nm
        <+> text "is an array variable, and we do not support this with"
        <+> text (smtWriterName conn ++ ".")
    Right smtType ->
      return smtType

-- | Create a fresh bound term from the SMT expression with the given name.
freshBoundTerm :: SMTCollectorState t h
               -> TypeMap tp
               -> Term h
               -> IO (SMTExpr h tp)
freshBoundTerm scs tp t = do
  SMTName tp <$> freshBoundFn scs [] (asSMTType tp) t

-- | Create a fresh bound term from the SMT expression with the given name.
freshBoundTerm' :: SupportTermOps (Term h)
                => SMTCollectorState t h
                -> SMTExpr h tp
                -> IO (SMTExpr h tp)
freshBoundTerm' scs t = do
  freshBoundTerm scs (smtExprType t) (asBase t)

-- | Create a fresh bound term from the SMT expression with the given name.
freshBoundFn :: SMTCollectorState t h
             -> [(Text, SMT_Type)] -- ^ Arguments expected for function.
             -> SMT_Type -- ^ Type of result
             -> Term h   -- ^ Result of function
             -> IO Text
freshBoundFn scs args tp t = do
  var <- withWriterState (scConn scs) $ freshVarName
  freshBoundTermFn scs var args tp t
  return var

-- | Assert a predicate holds as a side condition to some formula.
addSideCondition :: SMTCollectorState t h
                 -> String     -- ^ Reason that condition is being added.
                 -> Term h     -- ^ Predicate that should hold.
                 -> IO ()
addSideCondition scs nm t = do
  let conn = scConn scs
  let mf   = recordSideCondFn scs
  loc <- withWriterState conn $ use position
  case mf of
   Just f ->
     f t
   Nothing -> do
     fail $ "Cannot add a side condition within a function needed to define the "
       ++ nm ++ " term created at " ++ show loc ++ "."

mkFreeVar' :: SMTWriter h => WriterConn t h -> TypeMap tp -> IO (SMTExpr h tp)
mkFreeVar' conn tp = SMTName tp <$> mkFreeVar conn [] (asSMTType tp)

-- | This runs the collector on the connection
runOnLiveConnection :: SMTWriter h => WriterConn t h -> SMTCollector t h a -> IO a
runOnLiveConnection conn coll = runReaderT coll s
  where s = SMTCollectorState
              { scConn = conn
              , freshBoundTermFn = defineSMTVar conn
              , freshConstantFn  = Just $! FreshVarFn (mkFreeVar' conn)
              , recordSideCondFn = Just $! assumeFormula conn
              }

prependToRefList :: IORef [a] -> a -> IO ()
prependToRefList r a = seq a $ modifyIORef' r (a:)

freshSandboxBoundTerm :: SupportTermOps (Term h)
                      => IORef [(Text, Term h)]
                      -> Text -- ^ Name to define.
                      -> [(Text, SMT_Type)] -- Argument name and types.
                      -> SMT_Type
                      -> Term h
                      -> IO ()
freshSandboxBoundTerm ref var [] _ t = do
  prependToRefList ref (var,t)
freshSandboxBoundTerm ref var args _ t = do
  case lambdaTerm of
    Nothing -> do
      fail $ "Cannot create terms with arguments inside defined functions."
    Just lambdaFn -> do
      let r = lambdaFn args t
      seq r $ prependToRefList ref (var, r)

freshSandboxConstant :: WriterConn t h
                     -> IORef [(Text, SMT_Type)]
                     -> TypeMap tp
                     -> IO (SMTExpr h tp)
freshSandboxConstant conn ref tp = do
  var <- withWriterState conn $ freshVarName
  prependToRefList ref (var, asSMTType tp)
  return $! SMTName tp var

-- | This describes the result that was collected from the solver.
data CollectorResults h a =
  CollectorResults { crResult :: !a
                     -- ^ Result from sandboxed computation.
                   , crBindings :: !([(Text, Term h)])
                     -- ^ List of bound variables.
                   , crFreeConstants :: !([(Text, SMT_Type)])
                     -- ^ Constants added during generation.
                   , crSideConds :: !([Term h])
                     -- ^ List of Boolean predicates asserted by collector.
                   }

-- | Create a forall expression from a CollectorResult.
forallResult :: SupportTermOps (Term h)
             => CollectorResults h (Term h)
             -> Term h
forallResult cr =
  forallExpr (crFreeConstants cr) $
    letExpr (crBindings cr) $
      impliesAllExpr (crSideConds cr) (crResult cr)

-- | @impliesAllExpr l r@ returns an expression equivalent to
-- forall l implies r.
impliesAllExpr :: SupportTermOps v => [v] -> v -> v
impliesAllExpr l r = orAll ((notExpr <$> l) ++ [r])

-- | Create a forall expression from a CollectorResult.
existsResult :: SupportTermOps (Term h)
             => CollectorResults h (Term h)
             -> Term h
existsResult cr =
  existsExpr (crFreeConstants cr) $
    letExpr (crBindings cr) $
      andAll (crSideConds cr ++ [crResult cr])

-- | This runs the side collector and collects the results.
runInSandbox :: SupportTermOps (Term h)
             => WriterConn t h
             -> SMTCollector t h a
             -> IO (CollectorResults h a)
runInSandbox conn sc = do
  -- A list of bound terms.
  boundTermRef    <- newIORef []
  -- A list of free constants
  freeConstantRef <- newIORef []
  -- A list of references to side conditions.
  sideCondRef     <- newIORef []

  let s = SMTCollectorState
          { scConn = conn
          , freshBoundTermFn = freshSandboxBoundTerm boundTermRef
          , freshConstantFn  = Just $! FreshVarFn (freshSandboxConstant conn freeConstantRef)
          , recordSideCondFn = Just $! prependToRefList sideCondRef
          }
  r <- runReaderT sc s

  boundTerms    <- readIORef boundTermRef
  freeConstants <- readIORef freeConstantRef
  sideConds     <- readIORef sideCondRef
  return $! CollectorResults { crResult = r
                             , crBindings = reverse boundTerms
                             , crFreeConstants = reverse freeConstants
                             , crSideConds = reverse sideConds
                             }

-- | 'defineSMTFunction conn var action' will introduce a function
--
-- It returns the return type of the value.
-- Note: This function is declared at a global scope.  It bypasses
-- any subfunctions.  We need to investigate how to support nested
-- functions.
defineSMTFunction :: SMTWriter h
                  => WriterConn t h
                  -> Text
                  -> (FreshVarFn h -> SMTCollector t h (SMTExpr h ret))
                     -- ^ Action to generate
                  -> IO (TypeMap ret)
defineSMTFunction conn var action =
  withConnEntryStack conn $ do
    -- A list of bound terms.
    freeConstantRef <- newIORef []
    boundTermRef    <- newIORef []
    let s = SMTCollectorState { scConn = conn
                              , freshBoundTermFn = freshSandboxBoundTerm boundTermRef
                              , freshConstantFn  = Nothing
                              , recordSideCondFn = Nothing
                              }
    -- Associate a variable with each bound variable
    let varFn = FreshVarFn (freshSandboxConstant conn freeConstantRef)
    pair <- flip runReaderT s (action varFn)

    args       <- readIORef freeConstantRef
    boundTerms <- readIORef boundTermRef

    let res = letExpr (reverse boundTerms) (asBase pair)

    defineSMTVar conn var (reverse args) (asSMTType (smtExprType pair)) res
    return $! smtExprType pair

-- | Status to indicate when term value will be uncached.
data TermLifetime
   = DeleteNever
     -- ^ Never delete the term
   | DeleteOnPop
     -- ^ Delete the term when the current frame is popped.
  deriving (Eq)

-- | Cache the result of writing an Elt named by the given nonce.
cacheWriterResult :: SMTCollectorState t h
                   -> Nonce t tp
                      -- ^ Nonce to associate term with
                   -> TermLifetime
                      -- ^ Lifetime of term
                   -> IO (SMTExpr h tp)
                     -- ^ Action to create term.
                   -> IO (SMTExpr h tp)
cacheWriterResult scs n lifetime fallback = do
  let c = scConn scs
  mr <- liftIO $ cacheLookup c n
  case mr of
   Just x -> return x
   Nothing -> do
     x <- fallback
     cacheValue c n lifetime x
     return x

-- | Associate a bound variable with the givne SMT Expression until
-- the a
bindVar :: WriterConn t h
        -> SimpleBoundVar t tp
        -- ^ Variable to bind
        -> SMTExpr h tp
        -- ^ SMT Expression to bind to var.
        -> IO ()
bindVar c v x  = do
  let n = bvarId v
  mr <- cacheLookup c n
  case mr of
    Just{} -> fail "Variable is already bound."
    Nothing -> return ()
  cacheValue c n DeleteOnPop x

------------------------------------------------------------------------
-- Evaluate applications.

-- 'bvNatTerm h w x' builds an integer term term that has the same
-- value as the unsigned integer value of the bitvector 'x'.
-- This is done by explicitly decomposing the positional
-- notation of the bitvector into a sum of powers of 2.
bvIntTerm :: forall v w
           . (SupportTermOps v, 1 <= w)
          => NatRepr w
          -> v
          -> v
bvIntTerm w x = sumExpr ((\i -> digit (i-1)) <$> [1..natValue w])
 where digit :: Integer -> v
       digit d = ite (bvTestBit w d x)
                     (fromInteger (2^d))
                     (fromInteger 0)

sbvIntTerm :: SupportTermOps v
           => NatRepr w
           -> v
           -> v
sbvIntTerm w0 x0 = sumExpr (signed_offset : go w0 x0 (natValue w0 - 2))
 where signed_offset = ite (bvTestBit w0 (natValue w0 - 1) x0)
                           (fromInteger (negate (2^(widthVal w0 - 1))))
                           (fromInteger 0)
       go :: SupportTermOps v => NatRepr w -> v -> Integer -> [v]
       go w x n
        | n > 0     = digit w x n : go w x (n-1)
        | n == 0    = [digit w x 0]
        | otherwise = [] -- this branch should only be called in the degenerate case
                         -- of length 1 signed bitvectors

       digit :: SupportTermOps v => NatRepr w -> v -> Integer -> v
       digit w x d = ite (bvTestBit w d x)
                         (fromInteger (2^d))
                         (fromInteger 0)

unsupportedTerm  :: Monad m => Elt t tp -> m a
unsupportedTerm e =
  fail $ show $
    text "Cannot generate solver output for term generated at"
      <+> pretty (plSourceLoc (eltLoc e)) <> text ":" <$$>
    indent 2 (pretty e)

-- | Checks whether a variable is supported.
--
-- Returns the SMT type of the variable and a predicate (if needed) that the variable
-- should be assumed to hold.  This is used for Natural number variables.
checkVarTypeSupport :: SMTCollectorState t h -> SimpleBoundVar t tp -> IO ()
checkVarTypeSupport scs var = do
  let t = BoundVarElt var
  case bvarType var of
    BaseNatRepr     -> checkIntegerSupport scs t
    BaseIntegerRepr -> checkIntegerSupport scs t
    BaseRealRepr    -> checkLinearSupport scs t
    BaseComplexRepr -> checkLinearSupport scs t
    _ -> return ()

predSMTExpr :: forall t h tp
             . SMTWriter h
            => NonceAppElt t tp
            -> SMTCollector t h (SMTExpr h tp)
predSMTExpr e0 = do
  scs0 <- ask
  let conn = scConn scs0
  let i = NonceAppElt e0
  liftIO $ updateProgramLoc conn (nonceEltLoc e0)
  case nonceEltApp e0 of
    Forall var e -> do
      checkQuantifierSupport "universal quantifier" i
      liftIO $ do
      cr <- withConnEntryStack conn $ do
        runInSandbox conn $ do
          scs <- ask
          liftIO $ do
          let Just (FreshVarFn f) = freshConstantFn scs
          checkVarTypeSupport scs var
          smtType <- getBaseSMT_Type conn var

          t <- f smtType
          bindVar conn var t

          addPartialSideCond scs (asBase t) (bvarType var)
          asBase <$> mkExpr' scs e
      freshBoundTerm scs0 BoolTypeMap $ forallResult cr
    Exists var e -> do
      checkQuantifierSupport "existential quantifiers" i
      liftIO $ do
      cr <- withConnEntryStack conn $ do
        runInSandbox conn $ do
          scs <- ask
          Just (FreshVarFn f) <- asks freshConstantFn
          liftIO $ checkVarTypeSupport scs var
          smtType <- liftIO $ getBaseSMT_Type conn var

          t <- liftIO $ f smtType
          liftIO $ bindVar conn var t

          liftIO $ addPartialSideCond scs (asBase t) (bvarType var)
          mkBaseExpr e
      freshBoundTerm scs0 BoolTypeMap $ existsResult cr

    ArrayFromFn f -> do
      -- Evaluate arg types
      smt_arg_types <-
        traverseFC (evalFirstClassTypeRepr conn (eltSource i))
                   (symFnArgTypes f)
      -- Evaluate simple function
      (smt_f, ret_tp) <- liftIO $ getSMTSymFn conn f smt_arg_types

      let array_tp = FnArrayTypeMap smt_arg_types ret_tp
      return $! SMTName array_tp smt_f

    MapOverArrays f idx_types arrays -> do
      -- :: Ctx.Assignment (ArrayResultWrapper (Elt t) (idx Ctx.::> itp)) ctx)  -> do
      -- Evaluate arg types for indices.

      smt_idx_types <- traverseFC (evalFirstClassTypeRepr conn (eltSource i)) idx_types

      let evalArray :: forall idx itp etp
                     . I.ArrayResultWrapper (Elt t) (idx Ctx.::> itp) etp
                     -> SMTCollector t h (I.ArrayResultWrapper (SMTExpr h) (idx Ctx.::> itp) etp)
          evalArray (I.ArrayResultWrapper a) = I.ArrayResultWrapper <$> mkExpr a

      smt_arrays <- traverseFC evalArray arrays

      liftIO $ do

      -- Create name of function to reutrn.
      nm <- liftIO $ withWriterState conn $ freshVarName

      ret_type <-
        defineSMTFunction conn nm $ \(FreshVarFn freshVar) -> do
          -- Create type for indices.
          smt_indices <- traverseFC (\tp -> liftIO (freshVar tp)) smt_idx_types

          let idxl = toListFC asBase smt_indices
          let select :: forall  idxl idx etp
                     .  I.ArrayResultWrapper (SMTExpr h) (idxl Ctx.::> idx) etp
                     -> SMTExpr h etp
              select (I.ArrayResultWrapper a) = smt_array_select a idxl
          let array_vals = fmapFC select smt_arrays

          (smt_f, ret_type) <- liftIO $ getSMTSymFn conn f (fmapFC smtExprType array_vals)

          return $ SMTExpr ret_type $ smtFnApp (fromText smt_f) (toListFC asBase array_vals)


      let array_tp = FnArrayTypeMap smt_idx_types ret_type
      return $! SMTName array_tp nm

    ArrayTrueOnEntries{} -> do
      fail $ "SMTWriter does not yet support ArrayTrueOnEntries.\n" ++ show i

    FnApp f args -> do
      smt_args <- traverseFC mkExpr args
      liftIO $ do
      (smt_f, ret_type) <- getSMTSymFn conn f (fmapFC smtExprType smt_args)
      freshBoundTerm scs0 ret_type $ smtFnApp (fromText smt_f) (toListFC asBase smt_args)

theoryUnsupported :: Monad m => WriterConn t h -> String -> Elt t tp -> m a
theoryUnsupported conn theory_name t =
  fail $ show $
    text (smtWriterName conn) <+> text "does not support the" <+> text theory_name
    <+> text "term generated at" <+> pretty (plSourceLoc (eltLoc t)) <> text ":" <$$>
    indent 2 (pretty t)

checkIntegerSupport :: SMTCollectorState t h -> Elt t tp -> IO ()
checkIntegerSupport scs t = do
  let conn = scConn scs
  unless (supportedFeatures conn `hasProblemFeature` useIntegerArithmetic) $ do
    theoryUnsupported conn "integer arithmetic" t

checkLinearSupport :: SMTCollectorState t h -> Elt t tp -> IO ()
checkLinearSupport scs t = do
  let conn = scConn scs
  unless (supportedFeatures conn `hasProblemFeature` useLinearArithmetic) $ do
    theoryUnsupported conn "linear arithmetic" t

checkNonlinearSupport :: SMTCollectorState t h -> Elt t tp -> IO ()
checkNonlinearSupport scs t = do
  let conn = scConn scs
  unless (supportedFeatures conn `hasProblemFeature` useNonlinearArithmetic) $ do
    theoryUnsupported conn "non-linear arithmetic" t

checkComputableSupport :: SMTCollectorState t h -> Elt t tp -> IO ()
checkComputableSupport scs t = do
  let conn = scConn scs
  unless (supportedFeatures conn `hasProblemFeature` useComputableReals) $ do
    theoryUnsupported conn "computable arithmetic" t

checkQuantifierSupport :: String -> Elt t p -> SMTCollector t h ()
checkQuantifierSupport nm t = do
  conn <- asks scConn
  when (supportQuantifiers conn == False) $ do
    theoryUnsupported conn nm t

-- | Generate a SMTLIB function for a simplebuilder function.
--
-- Since SimpleBuilder different simple builder values with the same type may
-- have different SMTLIB types (particularly arrays), getSMTSymFn requires the
-- argument types to call the function with.  This is enforced to be compatible
-- with the argument types expected by the simplebuilder.
--
-- This function caches the result, and we currently generate the function based
-- on the argument types provided the first time getSMTSymFn is called with a
-- particular simple builder function.  In subsequent calls, we validate that
-- the same argument types are provided.  In principal, a function could be
-- called with one type of arguments, and then be called with a different type
-- and this check would fail.  However, due to limitations in the solvers we
-- expect to support, this should never happen as the only time these may differ
-- when arrays are used and one array is encoded using the theory of arrays, while
-- the other uses a defined function.  However, SMTLIB2 does not allow functions
-- to be passed to other functions; yices does, but always encodes arrays as functions.
--
-- Returns the name of the function and the type of the result.
getSMTSymFn :: SMTWriter h
            => WriterConn t h
            -> SimpleSymFn t args ret -- ^ Function to
            -> Ctx.Assignment TypeMap args
            -> IO (Text, TypeMap ret)
getSMTSymFn conn fn arg_types = do
  let n = symFnId fn
  let cache = smtFnCache conn
  me <- stToIO $ PH.lookup cache n
  case me of
    Just (SMTSymFn nm param_types ret) -> do
      when (arg_types /= param_types) $ do
        fail $ "Illegal arguments to function " ++ Text.unpack nm ++ "."
      return (nm, ret)
    Nothing -> do
      -- Check argument types can be passed to a function.
      checkArgumentTypes conn arg_types
      -- Generate name.
      nm <- getSymbolName conn (FnSymbolBinding fn)
      ret_type <- defineSMTSymFn conn nm fn arg_types
      stToIO $ PH.insert cache n $! SMTSymFn nm arg_types ret_type
      return $! (nm, ret_type)

-- | Check that the types can be passed to functions.
checkArgumentTypes :: WriterConn t h -> Ctx.Assignment TypeMap args -> IO ()
checkArgumentTypes conn types = do
  forMFC_ types $ \tp -> do
    case tp of
      FnArrayTypeMap{} | supportFunctionArguments conn == False -> do
          fail $ show $ text (smtWriterName conn)
             <+> text  "does not allow arrays encoded as functions to be function arguments."
      _ ->
        return ()

-- | This generates an error message from a solver and a type error.
--
-- It issed for error reporting
type SMTSource = String -> BaseTypeError -> Doc

ppBaseTypeError :: BaseTypeError -> Doc
ppBaseTypeError ComplexTypeUnsupported = text "complex values"
ppBaseTypeError ArrayUnsupported = text "arrays encoded as a functions"

eltSource :: Elt t tp -> SMTSource
eltSource e solver_name cause =
  text solver_name <+>
  text "does not support" <+> ppBaseTypeError cause <>
  text ", and cannot interpret the term generated at" <+>
  pretty (plSourceLoc (eltLoc e)) <> text ":" <$$>
  indent 2 (pretty e) <> text "."

fnSource :: SolverSymbol -> ProgramLoc -> SMTSource
fnSource fn_name loc solver_name cause =
  text solver_name <+>
  text "does not support" <+> ppBaseTypeError cause <>
  text ", and cannot interpret the function" <+> text (show fn_name) <+>
  text "generated at" <+> pretty (plSourceLoc loc) <> text "."

-- | Evaluate a base type repr as a first class SMT type.
--
-- First class types are those that can be passed as function arguments and
-- returned by functions.
evalFirstClassTypeRepr :: Monad m
                       => WriterConn t h
                       -> SMTSource
                       -> BaseTypeRepr tp
                       -> m (TypeMap tp)
evalFirstClassTypeRepr conn src base_tp =
  case typeMapNoFunction conn base_tp of
    Left e -> fail $ show $ src (smtWriterName conn) e
    Right smt_ret -> return smt_ret

type instance SymExpr (SMTCollectorState t h) = SMTExpr h

instance I.IsPred (SMTExpr h BaseBoolType) where

instance I.IsExpr (SMTExpr h) where
  exprType x = asBaseType (smtExprType x)
  printSymExpr (SMTName _ t) = text (Text.unpack t)
  printSymExpr (SMTExpr _ t) = text (show (renderTerm t))

instance SupportTermOps (Term h) => I.IsBoolExprBuilder (SMTCollectorState t h) where
  truePred _  = SMTExpr BoolTypeMap (boolExpr True)
  falsePred _ = SMTExpr BoolTypeMap (boolExpr False)
  notPred scs x =
    freshBoundTerm scs BoolTypeMap $ notExpr (asBase x)
  andPred scs x y =
    freshBoundTerm scs BoolTypeMap $ asBase x .&& asBase y
  xorPred scs x y =
    freshBoundTerm scs BoolTypeMap $ asBase x ./= asBase y
  itePred scs c x y =
    freshBoundTerm scs BoolTypeMap $
      ite (asBase c) (asBase x) (asBase y)

instance SupportTermOps (Term h) => I.IsExprBuilder (SMTCollectorState t h) where
  natLit _ n = return $! SMTExpr NatTypeMap (fromIntegral n)

  intLit _ i = return $! SMTExpr IntegerTypeMap (fromIntegral i)

-- | Create a SMT symbolic function from the SimpleSymFn.
--
-- Returns the return type of the function.
--
-- This is only called by 'getSMTSymFn'.
defineSMTSymFn :: SMTWriter h
                  => WriterConn t h
                  -- ^ Connection for adding command to.
                  -> Text
                     -- ^ Name of function to define
                  -> SimpleSymFn t args ret

                  -> Ctx.Assignment TypeMap args
                  -> IO (TypeMap ret)
defineSMTSymFn conn nm f arg_types =
  case symFnInfo f of
    UninterpFnInfo _ return_type -> do
      let fnm = symFnName f
      let l = symFnLoc f
      smt_ret <- evalFirstClassTypeRepr conn (fnSource fnm l) return_type
      addCommand conn $
        declareCommand conn nm (toListFC asSMTType arg_types) (asSMTType smt_ret)
      return $! smt_ret
    DefinedFnInfo arg_vars return_value _ -> do
      -- Define the SMT function
      defineSMTFunction conn nm $ \(FreshVarFn freshVar) -> do
        scs <- ask
        liftIO $ do
        -- Create SMT expressions and bind them to vars
        Ctx.forIndexM (Ctx.size arg_vars) $ \i -> do
          let v = arg_vars Ctx.! i
          let smtType = arg_types Ctx.! i
          checkVarTypeSupport scs v
          x <- freshVar smtType
          bindVar conn v x
        -- Evaluate return value
        mkExpr' scs return_value
    MatlabSolverFnInfo fn_id -> do
      defineSMTFunction conn nm $ \(FreshVarFn freshVar) -> do
        scs <- ask
        liftIO $ do
        fn_id' <- traverseMatlabSolverFn (mkExpr' scs) fn_id
        args <- traverseFC freshVar arg_types
        evalMatlabSolverFn fn_id' scs args

withConnEntryStack :: WriterConn t h -> IO a -> IO a
withConnEntryStack conn = bracket_ (pushEntryStack conn) (popEntryStack conn)

-- | Convert structure to list.
mkIndicesTerms :: SMTWriter h
               => Ctx.Assignment (Elt t) ctx
               -> SMTCollector t h [Term h]
mkIndicesTerms = foldrFC (\e r -> (:) <$> mkBaseExpr e <*> r) (pure [])

-- | Convert structure to list.
mkIndexLitTerms :: SupportTermOps v
                => Ctx.Assignment I.IndexLit ctx
                -> [v]
mkIndexLitTerms = toListFC mkIndexLitTerm

-- | Convert structure to list.
mkIndexLitTerm :: SupportTermOps v
               => I.IndexLit tp
               -> v
mkIndexLitTerm (I.NatIndexLit i) = fromIntegral i
mkIndexLitTerm (I.BVIndexLit w i) = bvTerm w i

-- | Create index arguments with given type.
--
-- Returns the name of the argument and the type.
createTypeMapArgsForArray :: forall t h args
                          .  WriterConn t h
                          -> Ctx.Assignment TypeMap args
                          -> IO [(Text, SMT_Type)]
createTypeMapArgsForArray conn types = do
  -- Create names for index variables.
  let mkIndexVar :: TypeMap utp -> IO (Text, SMT_Type)
      mkIndexVar base_tp = do
        i_nm <- withWriterState conn $ freshVarName' "i!"
        return (i_nm, asSMTType base_tp)
  -- Get SMT arguments.
  sequence $ toListFC mkIndexVar types

smt_array_select :: SupportTermOps (Term h)
                 => SMTExpr h (BaseArrayType (idxl Ctx.::> idx) tp)
                 -> [Term h]
                 -> SMTExpr h tp
smt_array_select aexpr idxl =
  case smtExprType aexpr of
    PrimArrayTypeMap _ res_type ->
      SMTExpr res_type $ arraySelect (asBase aexpr) idxl
    FnArrayTypeMap _ res_type ->
      SMTExpr res_type $ smtFnApp (asBase aexpr) idxl

appSMTExpr :: forall t h tp
            . SMTWriter h
           => AppElt t tp
           -> SMTCollector t h (SMTExpr h tp)
appSMTExpr ae = do
  scs <- ask
  let conn = scConn scs
  let i = AppElt ae
  liftIO $ updateProgramLoc conn (appEltLoc ae)
  case appEltApp ae of

    TrueBool  ->
      return $! I.truePred scs
    FalseBool ->
      return $! I.falsePred scs
    NotBool xe   -> do
      x <- mkExpr xe
      liftIO $ I.notPred scs x
    AndBool xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ I.andPred scs x y
    XorBool xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ I.xorPred scs x y
    IteBool ce xe ye -> do
      c <- mkExpr ce
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ I.itePred scs c x y

    RealEq xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs BoolTypeMap $ asBase x .== asBase y
    RealLe xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs BoolTypeMap $ asBase x .<= asBase y
    RealIsInteger rexpr -> do
      r <- mkExpr rexpr
      liftIO $ do
      freshBoundTerm scs BoolTypeMap $ realIsInteger (asBase r)
    BVTestBit n xe -> do
      x <- mkExpr xe

      liftIO $ do
      let this_bit = bvExtract (bvWidth xe) (toInteger n) 1 (asBase x)
          one = bvTerm (knownNat :: NatRepr 1) 1
      freshBoundTerm scs BoolTypeMap $ this_bit .== one
    BVEq xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs BoolTypeMap $ x .== y
    BVSlt xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs BoolTypeMap $ x `bvSLt` y
    BVUlt xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs BoolTypeMap $ x `bvULt` y
    ArrayEq xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      let xtp = smtExprType x
      let ytp = smtExprType y

      let checkArrayType z (FnArrayTypeMap{}) = do
            fail $ show $ text (smtWriterName conn) <+>
              text "does not support checking equality for the array generated at"
              <+> pretty (plSourceLoc (eltLoc z)) <> text ":" <$$>
              indent 2 (pretty z)
          checkArrayType _ _ = return ()
      checkArrayType xe xtp
      checkArrayType ye ytp
      when (xtp /= ytp) $ do
        fail $ "Array types are not equal."
      freshBoundTerm scs BoolTypeMap $ asBase x .== asBase y

    NatDiv xe ye -> do

      x <- mkBaseExpr xe
      y <- mkBaseExpr ye

      liftIO $ do
      nm <- freshConstant scs "nat div" NatTypeMap
      r  <- asBase <$> freshConstant scs "nat div" NatTypeMap
      let q = asBase nm
      case ye of
        NatElt{} -> return ()
        _ -> checkNonlinearSupport scs i
      -- Assume x can be composed into quotient and remainder.
      addSideCondition scs "nat div" $ x .== y * q + r .|| y .== 0
      addSideCondition scs "nat div" $ q .>= 0
      -- Add assertion about range of remainder.
      addSideCondition scs "nat div" $ r .>= 0
      addSideCondition scs "nat div" $ r .<  y .|| y .== 0
      -- Return name of variable.
      return nm

    ------------------------------------------
    -- Real operations.

    RealMul xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      checkNonlinearSupport scs i
      freshBoundTerm scs RealTypeMap $ asBase x * asBase y
    RealSum rs -> do
      rs1 <- WSum.traverseVars mkExpr rs

      let smul s e
            | s ==  1 = (:[]) <$> mkBaseExpr e
            | s == -1 = (:[]) . negate <$> mkBaseExpr e
            | otherwise = (:[]) . (rationalTerm s *) <$> mkBaseExpr e
      r <- WSum.eval (liftM2 (++)) smul (pure . (:[]) . rationalTerm) rs
      liftIO $ do
      freshBoundTerm scs RealTypeMap (sumExpr r)
    RealIte ce xe ye -> do
      c <- mkExpr ce
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs RealTypeMap $ ite (asBase c) (asBase x) (asBase y)
    RealDiv xe ye -> do
      x <- mkExpr xe
      case ye of
        RatElt r _ -> do
          liftIO $ do
          freshBoundTerm scs RealTypeMap $ asBase x * rationalTerm (recip r)
        _ -> do
          y <- mkExpr ye
          liftIO $ do
          r <- freshConstant scs "real divison" RealTypeMap
          checkNonlinearSupport scs i
          addSideCondition scs "real division" $
            (asBase y * asBase r) .== asBase x .|| asBase y .== 0
          return r
    IntMod xe ye -> do

      x <- mkBaseExpr xe
      y <- mkBaseExpr ye

      liftIO $ do
      q  <- asBase <$> freshConstant scs "integer mod" NatTypeMap
      nm <- freshConstant scs "integer mod" NatTypeMap
      let r = asBase nm
      case ye of
        NatElt{} -> return ()
        _ -> checkNonlinearSupport scs i
      -- Assume x can be composed into quotient and remainder.
      addSideCondition scs "integer mod" $ x .== y * q + r .|| y .== 0
      -- Add assertion about range of remainder.
      -- Note that IntMod is not defined when y = 0.
      addSideCondition scs "integer mod" $ 0 .<= r
      addSideCondition scs "integer mod" $ r .<  y .|| y .== 0
      -- Return name of variable.
      return nm
    RealSqrt xe -> do
      x <- mkBaseExpr xe
      liftIO $ do

      nm <- freshConstant scs "real sqrt" RealTypeMap
      let v = asBase nm
      checkNonlinearSupport scs i
      -- assert v*v = x
      addSideCondition scs "real sqrt" $ v * v .== x .|| x .== 0
      -- assert v >= 0
      addSideCondition scs "real sqrt" $ v .>= 0
      -- Return variable
      return nm
    Pi -> do
      unsupportedTerm i
    RealSin xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realSin (asBase x)
    RealCos xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realCos (asBase x)
    RealATan2 xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realATan2 (asBase x) (asBase y)
    RealSinh xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realSinh (asBase x)
    RealCosh xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realCosh (asBase x)
    RealExp xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realExp (asBase x)
    RealLog xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkComputableSupport scs i
      freshBoundTerm scs RealTypeMap $ realLog (asBase x)

    ------------------------------------------
    -- Bitvector operations

    BVUnaryTerm t -> do
      let w = UnaryBV.width t
      let entries = UnaryBV.unsignedRanges t

      entries' <- (traverse . _1) mkExpr entries

      liftIO $ do
      nm <- freshConstant scs "unary term" (BVTypeMap w)
      let nm_s = asBase nm
      forM_ entries' $ \(q,l,u) -> do
        -- Add assertion that for all values v in l,u, the predicate
        -- q is equivalent to v being less than or equal to the result
        -- of this term (denoted by nm)
        addSideCondition scs "unary term" $ asBase q .== nm_s `bvULe` (bvTerm w l)
        addSideCondition scs "unary term" $ asBase q .== nm_s `bvULe` (bvTerm w u)
      case entries of
        (_, l, _):_ | l > 0 -> do
          addSideCondition scs "unary term" $ bvTerm w l `bvULe` nm_s
        _ ->
          return ()
      return nm

    BVConcat w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvConcat (asBase x) (asBase y)

    BVSelect idx n xe -> do
      x <- mkExpr xe
      liftIO $ do
      freshBoundTerm scs (BVTypeMap n) $ do
        bvExtract (bvWidth x) (natValue idx) (natValue n) (asBase x)

    BVNeg w xe -> do
      x <- mkBaseExpr xe
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvNeg x

    BVAdd w xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvAdd x y

    BVMul w xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvMul x y

    BVUdiv w xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvUDiv x y

    BVUrem w xe ye -> do
      x <- mkBaseExpr xe
      y <- mkBaseExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvURem x y

    BVSdiv w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvSDiv (asBase x) (asBase y)

    BVSrem w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvSRem (asBase x) (asBase y)

    BVIte w _ ce xe ye -> do
      c <- mkExpr ce
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ ite (asBase c) (asBase x) (asBase y)

    BVShl w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvShl (asBase x) (asBase y)

    BVLshr w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvLshr (asBase x) (asBase y)

    BVAshr w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvAshr (asBase x) (asBase y)

    BVZext w' xe -> do
      x <- mkExpr xe
      liftIO $ do
      let w = bvWidth x
      let n = widthVal w' - widthVal w
      case someNat (fromIntegral n) of
        Just (Some w2) | Just LeqProof <- isPosNat w' -> do
          let zeros = bvTerm w2 0
          freshBoundTerm scs (BVTypeMap w') $ bvConcat zeros (asBase x)
        _ -> fail "invalid zero extension"

    BVSext w' xe -> do
      x <- mkExpr xe
      liftIO $ do
      let w = bvWidth x
      let n = natValue w' - natValue w
      case someNat n of
        Just (Some w2) | Just LeqProof <- isPosNat w' -> do
          let zeros = bvTerm w2 0
          let ones  = bvTerm w2 (2^n - 1)
          let sgn = bvTestBit w (natValue w - 1) (asBase x)
          freshBoundTerm scs (BVTypeMap w') $ bvConcat (ite sgn ones zeros) (asBase x)
        _ -> fail "invalid sign extension"

    BVTrunc w' xe -> do
      x <- mkExpr xe
      liftIO $ do
      let w = bvWidth x
      freshBoundTerm scs (BVTypeMap w') $ bvExtract w 0 (natValue w') (asBase x)
    BVBitNot w xe -> do
      x <- mkExpr xe
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvNot (asBase x)
    BVBitAnd w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvAnd (asBase x) (asBase y)
    BVBitOr w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (BVTypeMap w) $ bvOr (asBase x) (asBase y)
    BVBitXor _w xe ye -> do
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      freshBoundTerm scs (smtExprType x) $ bvXor (asBase x) (asBase y)

    ------------------------------------------------------------------------
    -- Array Operations

    ArrayMap _ _ (Hash.Map elts) def -> do
      base_array <- mkExpr def
      elt_exprs <- traverse mkExpr elts
      let array_type = smtExprType base_array
      liftIO $ do
      case array_type of
        PrimArrayTypeMap{} -> do
          let set_at_index :: Term h
                           -> Ctx.Assignment I.IndexLit ctx
                           -> Term h
                           -> Term h
              set_at_index ma idx elt =
                arrayUpdate ma (mkIndexLitTerms idx) elt
          freshBoundTerm scs array_type $
            Map.foldlWithKey set_at_index (asBase base_array) (asBase <$> elt_exprs)

        FnArrayTypeMap idx_types resType -> do
          case smtFnUpdate of
            Just updateFn -> do
              let set_at_index :: Term h
                               -> Ctx.Assignment I.IndexLit ctx
                               -> Term h
                               -> Term h
                  set_at_index ma idx elt =
                    updateFn ma (toListFC mkIndexLitTerm idx) elt
              freshBoundTerm scs array_type $
                Map.foldlWithKey set_at_index (asBase base_array) (asBase <$> elt_exprs)
            Nothing -> do
              -- Supporting arrays as functons requires that we can create
              -- function definitions.
              when (not (supportFunctionDefs conn)) $ do
                fail $ show $ text (smtWriterName conn) <+>
                  text "does not support arrays as functions."
              -- Create names for index variables.
              args <- createTypeMapArgsForArray conn idx_types
              -- Get list of terms for arguments.
              let idx_terms = fromText . fst <$> args
              -- Return value at index in base_array.
              let base_lookup = smtFnApp (asBase base_array) idx_terms
              -- Return if-then-else structure for next elements.
              let set_at_index prev_value idx_lits elt =
                    let update_idx = toListFC mkIndexLitTerm idx_lits
                        cond = andAll (zipWith (.==) update_idx idx_terms)
                     in ite cond (asBase elt) prev_value
              -- Get final expression for definition.
              let expr = Map.foldlWithKey set_at_index base_lookup elt_exprs
              -- Add command
              SMTName array_type <$> freshBoundFn scs args (asSMTType resType) expr

    ConstantArray idxRepr _bRepr ve -> do
      v <- mkExpr ve
      liftIO $ do
      let value_type = smtExprType v
      let smt_value_type = asSMTType value_type
      idx_types <-
        traverseFC (evalFirstClassTypeRepr conn (eltSource i)) idxRepr
      case arrayConstant of
        Just constFn
          | otherwise -> do
            let idx_smt_types :: [SMT_Type]
                idx_smt_types = toListFC asSMTType idx_types
            let tp = PrimArrayTypeMap idx_types value_type
            freshBoundTerm scs tp $!
              constFn idx_smt_types smt_value_type (asBase v)
        Nothing -> do
          when (not (supportFunctionDefs conn)) $ do
            fail $ show $ text (smtWriterName conn) <+>
              text "cannot encode constant arrays."
          -- Constant functions use unnamed variables.
          let array_type = FnArrayTypeMap idx_types value_type
          -- Create names for index variables.
          args <- createTypeMapArgsForArray conn idx_types
          SMTName array_type <$> freshBoundFn scs args (asSMTType value_type) (asBase v)

    MuxArray _idxRepr _bRepr ce xe ye -> do
      c <- mkExpr ce
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      let xtp = smtExprType x
      let ytp = smtExprType y
      case (xtp,ytp) of
        (PrimArrayTypeMap{}, PrimArrayTypeMap{}) | xtp == ytp ->
          freshBoundTerm scs xtp $ ite (asBase c) (asBase x) (asBase y)
        -- TODO: Support FnArrayTypeMap
        _ -> do
          fail $ "SMTWriter expects compatible array types."

    SelectArray _bRepr aexpr idxe -> do
      a <- mkExpr aexpr
      idx <- traverseFC mkExpr idxe
      liftIO $ do
      freshBoundTerm' scs $ smt_array_select a (toListFC asBase idx)

    UpdateArray _bRepr _ a_elt idx ve -> do
      a <- mkExpr a_elt
      updated_idx <- mkIndicesTerms idx
      value <- asBase <$> mkExpr ve
      let array_type = smtExprType a
      liftIO $ do
      case array_type of
        PrimArrayTypeMap _ _ -> do
          freshBoundTerm scs array_type $
            arrayUpdate (asBase a) updated_idx value
        FnArrayTypeMap idxTypes resType  -> do
          case smtFnUpdate of
            Just updateFn -> do
              freshBoundTerm scs array_type $ updateFn (asBase a) updated_idx value
            Nothing -> do
              -- Return value at index in base_array.
              args <- createTypeMapArgsForArray conn idxTypes

              let idx_terms = fromText . fst <$> args
              let base_array_value = smtFnApp (asBase a) idx_terms
              let cond = andAll (zipWith (.==) updated_idx idx_terms)
              let expr = ite cond value base_array_value
              SMTName array_type <$> freshBoundFn scs args (asSMTType resType) expr

    ------------------------------------------------------------------------
    -- Conversions.

    NatToInteger xe -> do
      x <- mkExpr xe
      return $ case x of
                 SMTName _ n -> SMTName IntegerTypeMap n
                 SMTExpr _ e -> SMTExpr IntegerTypeMap e
    IntegerToNat x -> do
      v <- mkExpr x
      -- We don't add a side condition here as 'IntegerToNat' is undefined
      -- when 'x' is negative.
      -- addSideCondition scs "integer to nat" (asBase v .>= 0)
      return $ case v of
                 SMTName _ n -> SMTName NatTypeMap n
                 SMTExpr _ e -> SMTExpr NatTypeMap e

    IntegerToReal xe -> do
      x <- mkExpr xe
      return $ SMTExpr RealTypeMap (termIntegerToReal (asBase x))
    RealToInteger xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkIntegerSupport scs i
      return $ SMTExpr IntegerTypeMap (termRealToInteger (asBase x))

    RoundReal xe -> do
      x <- mkExpr xe
      liftIO $ do
      nm <- freshConstant scs "round" IntegerTypeMap
      checkIntegerSupport scs i
      let r = termIntegerToReal (asBase nm)
      -- Round always rounds away from zero, so we
      -- first split "r = round(x)" into two cases
      -- depending on if "x" is non-negative.
      let posExpr = (2*asBase x - 1 .<  2*r) .&& (2*r .<= 2*asBase x + 1)
      let negExpr = (2*asBase x - 1 .<= 2*r) .&& (2*r .<  2*asBase x + 1)
      -- Add formula
      addSideCondition scs "round" $ asBase x .<  0 .|| posExpr
      addSideCondition scs "round" $ asBase x .>= 0 .|| negExpr
      return nm

    FloorReal xe -> do
      x <- mkBaseExpr xe
      liftIO $ do
      nm <- freshConstant scs "floor" IntegerTypeMap
      let floor_r = termIntegerToReal (asBase nm)
      checkIntegerSupport scs i
      addSideCondition scs "floor" $ (floor_r .<= x) .&& (x .< floor_r + 1)
      return nm

    CeilReal xe -> do
      x <- asBase <$> mkExpr xe
      liftIO $ do
      nm <- freshConstant scs "ceiling" IntegerTypeMap
      let r = termIntegerToReal (asBase nm)
      checkIntegerSupport scs i
      addSideCondition scs "ceiling" $ (x .<= r) .&& (r .< x + 1)
      return nm

    BVToInteger xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkLinearSupport scs i
      freshBoundTerm scs IntegerTypeMap $ bvIntTerm (bvWidth xe) (asBase x)

    SBVToInteger xe -> do
      x <- mkExpr xe
      liftIO $ do
      checkLinearSupport scs i
      freshBoundTerm scs IntegerTypeMap $ sbvIntTerm (bvWidth xe) (asBase x)

    IntegerToSBV xe w -> do
      x <- mkExpr xe
      liftIO $ do
      res <- freshConstant scs "integerToSBV" (BVTypeMap w)
      let xb = asBase x
      addSideCondition scs "integerToSBV" $
        xb .<  fromInteger (minSigned w)
        .|| xb .> fromInteger (maxSigned w)
        .|| xb .== sbvIntTerm w (asBase res)
      return res

    IntegerToBV xe w -> do
      x <- mkExpr xe
      liftIO $ do
      res <- freshConstant scs "integerToBV" (BVTypeMap w)
      let xb = asBase x
      -- To ensure there is some solution regardless of xe being negative, we
      -- accept any model where xb is out of range.
      addSideCondition scs "integerToBV" $
         xb .< 0
         .|| xb .> fromInteger (maxUnsigned w)
         .|| xb .== bvIntTerm w (asBase res)

      return res

    Cplx ce -> do
      (r' :+ i') <- traverse mkExpr ce
      liftIO $ do

      let feat = supportedFeatures conn

      case () of
        _ | feat `hasProblemFeature` useStructs -> do
            let tp = ComplexToStructTypeMap
            freshBoundTerm scs tp $! structCtor [asBase r', asBase i']
          | feat `hasProblemFeature` useSymbolicArrays -> do
            let tp = ComplexToArrayTypeMap
            ra <-
              case arrayConstant of
              Just constFn  ->
                return $! constFn [SMT_BoolType] SMT_RealType (asBase r')
              Nothing -> do
                a <- freshConstant scs "complex lit" tp
                return $! arrayUpdate (asBase a) [boolExpr False] (asBase r')
            freshBoundTerm scs tp $! arrayUpdate ra [boolExpr True] (asBase i')
          | otherwise ->
            theoryUnsupported conn "complex literals" i

    RealPart e -> do
      c <- mkExpr e
      liftIO $ do
      case smtExprType c of
        ComplexToStructTypeMap ->
          freshBoundTerm scs RealTypeMap $ structComplexRealPart (asBase c)
        ComplexToArrayTypeMap ->
          freshBoundTerm scs RealTypeMap $ arrayComplexRealPart (asBase c)
    ImagPart e -> do
      c <- mkExpr e
      liftIO $ do
      case smtExprType c of
        ComplexToStructTypeMap ->
          freshBoundTerm scs RealTypeMap $ structComplexImagPart (asBase c)
        ComplexToArrayTypeMap ->
          freshBoundTerm scs RealTypeMap $ arrayComplexImagPart (asBase c)

    --------------------------------------------------------------------
    -- Structures

    StructCtor _ vals -> do
      -- Make sure a struct with the given number of elements has been declared.
      exprs <- traverseFC  mkExpr vals
      liftIO $ do
      declareStructDatatype conn (Ctx.sizeInt (Ctx.size vals))
      let fld_types = fmapFC smtExprType exprs
      freshBoundTerm scs (StructTypeMap fld_types) $
        structCtor (toListFC asBase exprs)
    StructField s idx _tp -> do
      expr <- mkExpr s
      liftIO $ do
      case smtExprType expr of
       StructTypeMap flds -> do
         let tp = flds Ctx.! idx
         let n = Ctx.sizeInt (Ctx.size flds)
         freshBoundTerm scs tp $
           structFieldSelect n (asBase expr) (Ctx.indexVal idx)
    StructIte _ pe xe ye -> do
      p <- mkExpr pe
      x <- mkExpr xe
      y <- mkExpr ye
      liftIO $ do
      when (smtExprType x /= smtExprType y) $ do
        fail $ "Expected structs to have same type."
      let tp = smtExprType x
      freshBoundTerm scs tp $ ite (asBase p) (asBase x) (asBase y)

------------------------------------------------------------------------
-- Writer high-level interface.

-- | Convert an element to a base expression.
mkBaseExpr :: SMTWriter h => Elt t tp -> SMTCollector t h (Term h)
mkBaseExpr e = asBase <$> mkExpr e

addPartialSideCond :: SupportTermOps (Term h)
                   => SMTCollectorState t h -> Term h -> BaseTypeRepr tp -> IO ()
addPartialSideCond scs t BaseNatRepr = addSideCondition scs "nat" $ t .>= 0
addPartialSideCond _ _ _ = return ()

-- | Get name associated with symbol binding if defined, creating it if needed.
getSymbolName :: WriterConn t h -> SymbolBinding t -> IO Text
getSymbolName conn b =
  case Bimap.lookupR b (varBindings conn) of
    Just sym -> return $! solverSymbolAsText sym
    Nothing -> withWriterState conn $ freshVarName

mkExpr' :: SMTWriter h => SMTCollectorState t h -> Elt t tp -> IO (SMTExpr h tp)
mkExpr' scs t@(NatElt n _) = do
  checkLinearSupport scs t
  I.natLit scs n
mkExpr' scs t@(IntElt i _) = do
  checkLinearSupport scs t
  I.intLit scs i
mkExpr' scs t@(RatElt r _) = do
  checkLinearSupport scs t
  return (SMTExpr RealTypeMap (rationalTerm r))
mkExpr' _ (BVElt w x _) =
  return $ SMTExpr (BVTypeMap w) $ bvTerm w x
mkExpr' scs (NonceAppElt ea) =
  cacheWriterResult scs (nonceEltId ea) DeleteOnPop $
    runReaderT (predSMTExpr ea) scs
mkExpr' scs (AppElt ea) =
  cacheWriterResult scs (appEltId ea) DeleteOnPop $ do
    flip runReaderT scs $ do
      appSMTExpr ea
mkExpr' scs (BoundVarElt var) = do
  let conn = scConn scs
  case bvarKind var of
   QuantifierVarKind -> do
     mr <- cacheLookup conn (bvarId var)
     case mr of
      Just x -> return x
      Nothing -> do
        fail $ "Internal error in SMTLIB exporter due to unbound variable "
            ++ show (bvarId var) ++ " defined at "
            ++ show (plSourceLoc (bvarLoc var)) ++ "."
   LatchVarKind ->
     fail $ "SMTLib exporter does not support the latch defined at "
            ++ show (plSourceLoc (bvarLoc var)) ++ "."
   UninterpVarKind -> do
     cacheWriterResult scs (bvarId var) DeleteNever $ do
       checkVarTypeSupport scs var
       -- Use predefined var name if it has not been defined.
       var_name <- getSymbolName conn (VarSymbolBinding var)
       smt_type <- getBaseSMT_Type conn var
       -- Add command
       addCommand conn $ declareCommand conn var_name [] (asSMTType smt_type)
       -- Add assertion based on var type.
       addPartialSideCond scs (fromText var_name) (bvarType var)
       -- Return variable name
       return $ SMTName smt_type var_name

-- | Convert an expression into a SMT Expression.
mkExpr :: SMTWriter h => Elt t tp -> SMTCollector t h (SMTExpr h tp)
mkExpr e = do
  scs <- ask
  liftIO $ mkExpr' scs e

-- | Write a logical expression.
mkFormula :: SMTWriter h => WriterConn t h -> BoolElt t -> IO (Term h)
mkFormula conn p = runOnLiveConnection conn $ mkBaseExpr p

-- | Write assume formula predicates for asserting predicate holds.
assume :: SMTWriter h => WriterConn t h -> BoolElt t -> IO ()
assume c p = do
  forM_ (asConjunction p) $ \v -> do
    f <- mkFormula c v
    updateProgramLoc c (eltLoc v)
    assumeFormula c f

data SMTEvalFunctions h
   = SMTEvalFunctions { smtEvalBool :: Term h -> IO Bool
                        -- ^ Given a SMT term for a Boolean value, this should
                        -- whether the term is assigned true or false.
                      , smtEvalBV   :: Int -> Term h -> IO Integer
                        -- ^ Given a bitwidth, and a SMT term for a bitvector
                        -- with that bitwidth, this should return an unsigned
                        -- integer with the value of that bitvector.
                      , smtEvalReal :: Term h -> IO Rational
                        -- ^ Given a SMT term for real value, this should
                        -- return a rational value for that term.
                      }

-- | Return the terms associated with the given ground index variables.
smtIndicesTerms :: forall v idx
                .  SupportTermOps v
                => Ctx.Assignment TypeMap idx
                -> Ctx.Assignment GroundValueWrapper  idx
                -> [v]
smtIndicesTerms tps vals = Ctx.forIndexRange 0 sz f []
  where sz = Ctx.size tps
        f :: Ctx.Index idx tp -> [v] -> [v]
        f i l = (r:l)
         where GVW v = vals Ctx.! i
               r = case tps Ctx.! i of
                      NatTypeMap -> rationalTerm (fromIntegral v)
                      BVTypeMap w -> bvTerm w v
                      _ -> error "Do not yet support other index types."

getSolverVal :: SupportTermOps (Term h)
              => SMTEvalFunctions h
              -> TypeMap tp
              -> Term h
              -> IO (GroundValue tp)
getSolverVal smtFns BoolTypeMap   tm = smtEvalBool smtFns tm
getSolverVal smtFns (BVTypeMap w) tm = smtEvalBV smtFns (widthVal w) tm
getSolverVal smtFns RealTypeMap   tm = smtEvalReal smtFns tm
getSolverVal smtFns NatTypeMap    tm = do
  r <- smtEvalReal smtFns tm
  when (denominator r /= 1 && numerator r < 0) $ do
    fail $ "Expected natural number from solver."
  return (fromInteger (numerator r))
getSolverVal smtFns IntegerTypeMap tm = do
  r <- smtEvalReal smtFns tm
  when (denominator r /= 1) $ fail "Expected integer value."
  return (numerator r)
getSolverVal smtFns ComplexToStructTypeMap tm =
  (:+) <$> smtEvalReal smtFns (structComplexRealPart tm)
       <*> smtEvalReal smtFns (structComplexImagPart tm)
getSolverVal smtFns ComplexToArrayTypeMap tm =
  (:+) <$> smtEvalReal smtFns (arrayComplexRealPart tm)
       <*> smtEvalReal smtFns (arrayComplexImagPart tm)
getSolverVal smtFns (PrimArrayTypeMap idx_types eltTp) tm = return $ \i -> do
  let res = arraySelect tm (smtIndicesTerms idx_types i)
  getSolverVal smtFns eltTp res
getSolverVal smtFns (FnArrayTypeMap idx_types eltTp) tm = return $ \i -> do
  let term = smtFnApp tm (smtIndicesTerms idx_types i)
  getSolverVal smtFns eltTp term
getSolverVal  smtFns (StructTypeMap flds0) tm =
          Ctx.traverseWithIndex (f flds0) flds0
        where f :: Ctx.Assignment TypeMap ctx
                -> Ctx.Index ctx utp
                -> TypeMap utp
                -> IO (GroundValueWrapper utp)
              f flds i tp = GVW <$> getSolverVal smtFns tp v
                where n = Ctx.sizeInt (Ctx.size flds)
                      v = structFieldSelect n tm (Ctx.indexVal i)

-- | The function creates a function for evaluating elts to concrete values
-- given a connection to an SMT solver along with some functions for evaluating
-- different types of terms to concrete values.
smtExprGroundEvalFn :: forall t h
                     . SMTWriter h
                    => WriterConn t h
                       -- ^ Connection to SMT solver.
                    -> SMTEvalFunctions h
                    -> IO (GroundEvalFn t)
smtExprGroundEvalFn conn smtFns = do
  -- Get solver features
  groundCache <- newIdxCache

  let cachedEval :: Elt t tp -> IO (GroundValue tp)
      cachedEval e =
        case eltMaybeId e of
          Nothing -> evalGroundElt cachedEval e
          Just e_id -> fmap unGVW $ idxCacheEval' groundCache e_id $ fmap GVW $ do
            -- See if we have bound the Elt e to a SMT expression.
            me <- cacheLookup conn e_id
            case me of
              -- Otherwise, try the evalGroundElt function to evaluate a ground element.
              Nothing -> evalGroundElt cachedEval e

              -- If so, try asking the solver for the value of SMT expression.
              Just (SMTName tp nm) ->
                getSolverVal smtFns tp (fromText nm)

              Just (SMTExpr tp expr) ->
                runMaybeT (tryEvalGroundElt cachedEval e) >>= \case
                  Just x  -> return x
                  -- If we cannot compute the value ourself, query the
                  -- value from the solver directly instead.
                  Nothing -> getSolverVal smtFns tp expr


  return $ GroundEvalFn cachedEval