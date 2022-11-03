{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE RecordWildCards #-}

module Plugin (plugin) where

import Data.Foldable (fold)
import Data.List (find, findIndex)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromJust, fromMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Tuple (swap)
import Prelude hiding ((<>))
import qualified Prelude

import GHC.Builtin.Types
import qualified GHC.Core as C
import GHC.Core.Class
import GHC.Core.Coercion
import GHC.Core.DataCon
import GHC.Core.Predicate
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import qualified GHC.Driver.Config.Finder as Finder
import GHC.Driver.Env (HscEnv (..))
import GHC.Driver.Plugins hiding (TcPlugin)
import GHC.Tc.Plugin
import GHC.Tc.Types
import GHC.Tc.Types.Constraint
import GHC.Tc.Types.Evidence
import qualified GHC.Types.Literal as L
import GHC.Types.Name.Occurrence
import GHC.Types.RepType
import GHC.Types.Unique.FM
import GHC.Types.Var.Set
import GHC.Unit.Env (ue_units, unsafeGetHomeUnit)
import qualified GHC.Unit.Finder as Finder
import GHC.Unit.Module.Name
import GHC.Unit.Types
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Utils.Trace

keepMaybe :: (a -> Maybe b) -> (a -> Maybe (a, b))
keepMaybe f a = fmap (a,) $ f a

{-
 - Data Types
 -}

instance Ord TyCon where
  compare = nonDetCmpTc

instance Eq Type where
  (==) = eqType

instance Ord Type where
  compare = nonDetCmpType

data OpFun
  = OpReplace
  | OpR
  | OpX
  | OpN
  | OpLookup
  | OpLen
  | OpAppend
  | OpSucc
  | OpZero
  | OpDrop
  | OpPair
  | OpSub
  | OpCons
  | OpNil
  | OpHCons
  | OpTake
  | OpHList
  | OpPower
  | OpEmpty
  | OpAccessLevel
  | OpDisequality
  | OpTrue
  | OpOther TyCon
  deriving (Eq, Ord)

data OpClass
  = OpEquality
  | OpAcceptable
  | OpAcceptableList
  | OpLeq
  deriving (Eq)

data OpType
  = OpApp OpFun [OpType]
  -- ^ Function application, such as @OpApp OpLookup [kind, elems, index]@
  | OpVar Var
  -- ^ Type and kind variables
  | OpLift Type
  -- ^ Unused
  | OpMultiAppend OpType OpType [OpType]
  -- ^ Contained kind, list, additions
  | OpShift OpType OpType Int
  -- ^ For constraints such as @Lookup (Append p X) (Length p)@, where
  -- we statically can tell that @Lookup (Append p X) (Length p) ~ X@.
  --
  -- We use this Shift to remember even more index information, e.g. to translate
  -- @Lookup (Append (Append p n) m) (S (Length p))@ into something like:
  -- @OpShift kind [n, m] 1@.
  | OpList OpType [OpType]
  -- ^ More efficient representation of lists.
  -- Could be expressed via qOpApp OpCons [kind, OpApp OpCons ...]@
  deriving (Eq, Ord)


-- | Constraint that we know how to handle and produce better constraints.
--
-- @'OpConstraint' class types@
data OpConstraint = OpConstraint OpClass [OpType]
  deriving (Eq)

-- | Set of constraints we know how to handle.
-- Contains information whether this constraint has been improved during this run.
data OpConstraintSet = OpConstraintSet [OpConstraint] Bool
  deriving (Eq)

instance Outputable OpConstraintSet where
  ppr (OpConstraintSet cts _) = brackets (interpp'SP cts)

instance Outputable OpConstraint where
  ppr (OpConstraint OpEquality [t1, t2]) = ppr t1 <> text " ~ " <> ppr t2
  ppr (OpConstraint OpAcceptable [a, b, c]) =
    text "OpAcceptable"
      <> parens
        ( ppr a
            <> comma
            <> space
            <> ppr b
            <> comma
            <> space
            <> ppr c
        )
  ppr (OpConstraint OpAcceptableList [a, b, c]) =
    text "OpAcceptableList"
      <> parens
        ( ppr a
            <> comma
            <> space
            <> ppr b
            <> comma
            <> space
            <> ppr c
        )
  ppr (OpConstraint OpLeq [a, b]) = ppr a <> text " ≤ " <> ppr b

instance Outputable OpFun where
  ppr OpDisequality = text "OpDisequality"
  ppr OpLookup = text "Lookup"
  ppr OpLen = text "Len"
  ppr OpAppend = text "Append"
  ppr OpReplace = text "Replace"
  ppr OpZero = text "Z"
  ppr OpSucc = text "S"
  ppr OpTake = text "Take"
  ppr OpDrop = text "Drop"
  ppr OpPower = text "Power"
  ppr OpEmpty = text "Empty"
  ppr OpSub = text "OpSub"
  ppr OpCons = text "Cons"
  ppr OpNil = text "Nil"
  ppr OpPair = text "Pair"
  ppr OpHCons = text "HCons"
  ppr OpHList = text "HList"
  ppr OpR = text "OpR"
  ppr OpX = text "OpX"
  ppr OpN = text "OpN"
  ppr OpAccessLevel = text "OpAccessLevel"
  ppr OpTrue = text "OpTrue"
  ppr (OpOther tc) = ppr tc

instance Outputable OpType where
  ppr (OpApp f []) = ppr f
  ppr (OpApp f op) = ppr f <> parens (interpp'SP op)
  ppr (OpVar v) = ppr v
  ppr (OpLift t) = ppr t
  ppr (OpMultiAppend a b args) = text "OpMultiAppend" <> brackets (ppr b) <> parens (interpp'SP args)
  ppr (OpShift a b i) = text "OpShift" <> parens (ppr a <> comma <> space <> ppr b <> comma <> space <> ppr i)
  ppr (OpList a xs) = brackets (interpp'SP xs)

{-
 - Loading Code
 -}

lookupModule :: String -> TcPluginM Module
lookupModule name = do
  hsc_env <- getTopEnv
  let fc = hsc_FC hsc_env
      unit_env = hsc_unit_env hsc_env
      fopts = Finder.initFinderOpts $ hsc_dflags hsc_env
      unitState = ue_units unit_env
  found_module <- tcPluginIO $ Finder.findPluginModule fc fopts unitState (Just $ unsafeGetHomeUnit unit_env) (mkModuleName name)
  case found_module of
    Found _ the_module -> return the_module
    _ -> panicDoc "Unable to find the module" (empty)

lookupTyCon :: Module -> String -> TcPluginM TyCon
lookupTyCon search_module name =
  tcLookupTyCon =<< lookupOrig search_module (mkTcOcc name)

lookupDataCon :: Module -> String -> TcPluginM DataCon
lookupDataCon search_module name =
  tcLookupDataCon =<< lookupOrig search_module (mkDataOcc name)

lookupClass :: Module -> String -> TcPluginM Class
lookupClass search_module name =
  tcLookupClass =<< lookupOrig search_module (mkTcOcc name)

-- | Convert a type we find into something that we can handle.
-- If it is just a variable, just take it, otherwise, translate the type family
-- application.
convert :: State -> Type -> OpType
convert s op = case op of
  TyVarTy v -> OpVar v
  TyConApp tc args -> OpApp (convertFun s tc) (map (convert s) args)
  t -> panicDoc "conversion failure" $ ppr t

-- | Convert known type constructors into something we know.
-- This list has been created statically.
convertFun :: State -> TyCon -> OpFun
convertFun s tc =
  case lookup tc (getTyCon s) of
    Nothing -> OpOther tc
    Just a -> a

-- | Translate the types into something that GHC understands.
-- Used for actually generating constraints that GHC might use to
-- solve the types.
deconvert :: State -> OpType -> Type
deconvert s op =
  case op of
    OpApp fun args -> TyConApp (deconvertFun s fun) (map (deconvert s) args)
    OpVar v -> TyVarTy v
    OpLift t -> t
    OpMultiAppend a b [] -> deconvert s b
    OpMultiAppend a b (x : xs) -> deconvert s (OpMultiAppend a (OpApp OpAppend [a, b, x]) xs)
    OpShift a b 0 -> deconvert s $ OpApp OpLen [a, b]
    OpShift a b c -> deconvert s $ OpApp OpSucc [OpShift a b (c - 1)]
    OpList a [] -> TyConApp promotedNilDataCon [deconvert s a]
    OpList a (x : xs) -> TyConApp promotedConsDataCon [deconvert s a, deconvert s x, deconvert s (OpList a xs)]

deconvertFun :: State -> OpFun -> TyCon
deconvertFun s fun =
  case fun of
    OpOther tc -> tc
    _ -> case lookup fun s' of
      Just m -> m
      Nothing -> error (showSDocUnsafe (ppr fun))
 where
  s' = map swap (getTyCon s)

data State = State
  { getTyCon :: [(TyCon, OpFun)]
  , getClass :: [(Class, OpClass)]
  }

buildState :: TcPluginM State
buildState = do
  tcPluginIO $ putStrLn "---init---"
  my_module <- lookupModule "Utils"
  mappingTyCon <-
    mapM
      (\(a, b) -> (,a) <$> b)
      [ (OpLookup, lookupTyCon my_module "Lookup")
      , (OpLen, lookupTyCon my_module "Length")
      , (OpAppend, lookupTyCon my_module "Append")
      , (OpZero, promoteDataCon <$> lookupDataCon my_module "Z")
      , (OpSucc, promoteDataCon <$> lookupDataCon my_module "S")
      , (OpReplace, lookupTyCon my_module "Replace")
      , (OpCons, return promotedConsDataCon)
      , (OpNil, return promotedNilDataCon)
      , (OpTrue, return promotedTrueDataCon)
      , (OpR, promoteDataCon <$> lookupDataCon my_module "R")
      , (OpX, promoteDataCon <$> lookupDataCon my_module "X")
      , (OpN, promoteDataCon <$> lookupDataCon my_module "N")
      , (OpAccessLevel, lookupTyCon my_module "AccessLevel")
      , (OpDisequality, lookupTyCon my_module "≠")
      ]
  mappingClass <-
    mapM
      (\(a, b) -> (,a) <$> b)
      [ (OpAcceptable, lookupClass my_module "Acceptable")
      , (OpAcceptableList, lookupClass my_module "AcceptableList")
      , (OpLeq, lookupClass my_module "≤")
      ]
  return $ State mappingTyCon mappingClass

-- | Translate a natural number to the peano representation.
getNum :: Int -> OpType
getNum 0 = OpApp OpZero []
getNum x = OpApp OpSucc [getNum (x - 1)]

mk :: OpFun -> OpType
mk f = OpApp f []

getDirectiveVars :: OpType -> [Var]
getDirectiveVars (OpVar v) = [v]
getDirectiveVars (OpApp (OpOther t) args)
  | isPromotedDataCon t = args >>= getDirectiveVars
getDirectiveVars _ = []

getVars :: OpType -> [Var]
getVars (OpVar v) = [v]
getVars (OpApp _ args) =
  args >>= getVars
getVars (OpShift a b _) =
  [a, b] >>= getVars
getVars (OpMultiAppend a b c) =
  (a : b : c) >>= getVars
getVars _ = []

align :: OpConstraintSet -> OpConstraintSet
align (OpConstraintSet t ch) = OpConstraintSet (map alignHelper t) ch

alignHelper :: OpConstraint -> OpConstraint
alignHelper (OpConstraint OpEquality [t1, t2])
  | null t2' && not (null t2'') = OpConstraint OpEquality [t1, t2]
  | otherwise = OpConstraint OpEquality [t2, t1]
 where
  t1' = getDirectiveVars t1
  t2' = getDirectiveVars t2
  t1'' = getVars t1
  t2'' = getVars t2
alignHelper x = x

-- | If possible, translate a fully saturated Class Constraint to
-- something that we can handle later.
handleClass :: State -> Class -> [Type] -> Maybe OpConstraintSet
handleClass st cl args =
  case op of
    Just a ->
      Just $ OpConstraintSet [OpConstraint a (map (convert st) args)] False
    _ -> Nothing
 where
  -- Is this a class that we actually know?
  op = lookup cl (getClass st)

-- | Convert Ct (Class Constraints) to the set of constraint
-- that we know how to handle.
handle :: State -> Ct -> Maybe OpConstraintSet
handle st ct =
  case classifyPredType (ctPred ct) of
    EqPred NomEq a b -> Just $ OpConstraintSet [OpConstraint OpEquality [convert st a, convert st b]] False
    ClassPred cl args -> handleClass st cl args
    _ -> Nothing

deconvertConstraint :: State -> OpConstraint -> Type
deconvertConstraint st c =
  case c of
    OpConstraint OpEquality [t1, t2] -> mkPrimEqPred (deconvert st t1) (deconvert st t2)
    OpConstraint other args -> mkClassPred (fromJust $ lookup other s') (map (deconvert st) args)
 where
  s' = map swap (getClass st)

deconvertConstraintSet :: State -> OpConstraintSet -> [Type]
deconvertConstraintSet st (OpConstraintSet cts _) =
  map (deconvertConstraint st) cts

turnIntoCt :: State -> (Ct, OpConstraintSet) -> (EvTerm, Ct)
turnIntoCt st (ct, x)
  | l2 == 0 = (EvExpr (C.Cast (C.Coercion (Refl boolTy)) ev2), ct)
  | l2 == 1 = (EvExpr (C.Cast (C.App (C.Var (dataConWorkId charDataCon)) (C.Lit (L.LitChar 'c'))) ev1), ct)
  | otherwise = error (show (l1, l2, l3))
 where
  ev1 = mkUnivCo (PluginProv "linearity") Representational (charTy) (ctPred ct)
  ev2 = mkUnivCo (PluginProv "linearity") Representational (mkPrimEqPred boolTy boolTy) (ctPred ct)
  l1 = length $ typePrimRep (charTy)
  l2 = length $ typePrimRep (ctPred ct)
  l3 = length $ typePrimRep (mkPrimEqPred boolTy boolTy)

makeIntoCt :: State -> (Ct, OpConstraintSet) -> TcPluginM [Ct]
makeIntoCt st (ct, x) = do
  let loc = ctLoc ct
  map mkNonCanonical <$> mapM (newWanted loc) (deconvertConstraintSet st x)

hasChanged :: OpConstraintSet -> Bool
hasChanged (OpConstraintSet _ ch) = ch

{-
 - Simplification, Part 1
 -}

improveAux :: KnownConstraints -> OpType -> OpType
{-improveAux (OpApp OpLookup [a, OpMultiAppend a' base (x:xs), OpApp OpLen [a'', base']])
  | a == a' && a' == a'' && base == base' = x-}
improveAux info (OpApp OpLookup [a, OpMultiAppend a' base xs, OpShift a'' base' i])
  | {-a == a' && a' == a'' &&-} compatible (getUnionFind info) base base' && i < length xs = xs !! i
improveAux info (OpApp OpLookup [a, OpMultiAppend a' (OpApp OpReplace [a''', OpVar base, c, d]) xs, e])
  | Just _ <- Map.lookup (base, e) (equalityConstraintsUnrefined info) = OpApp OpLookup [a, OpApp OpReplace [a''', OpVar base, c, d], e]
improveAux info (OpApp OpDisequality [_, e, OpShift _ (OpVar base) _])
  | Just _ <- Map.lookup (base, e) (equalityConstraintsUnrefined info) = OpApp OpTrue []
improveAux info (OpApp OpLookup [a, OpApp OpReplace [a', OpVar base, e', _], e]) -- = error $ show info
  | (e, e') `elem` (disequalityConstraints info) = OpApp OpLookup [a, OpVar base, e]
improveAux _ (OpMultiAppend a (OpMultiAppend a' base xs) ys)
  | a == a' = OpMultiAppend a base (xs ++ ys)
improveAux _ (OpApp OpReplace [a, OpMultiAppend a' base xs, OpShift a'' base' i, x])
  | {-a == a' && a' == a'' &&-} base == base' && i < length xs = OpMultiAppend a base (take i xs ++ [x] ++ drop (i + 1) xs)
improveAux _ (OpApp OpSub [OpShift a xs i, OpShift a' xs' i'])
  | a == a' && xs == xs' && i <= i' = getNum (i' - i)
improveAux _ (OpApp OpReplace [a, OpApp OpReplace [a', base, i', x'], i, x])
  | {-a == a' &&-} i' == i = OpApp OpReplace [a, base, i, x]
improveAux _ (OpApp OpLookup [a, OpApp OpReplace [a', _, i', x'], i])
  | {-a == a' &&-} i == i' = x'
improveAux _ (OpApp OpReplace [a, OpMultiAppend a' (OpApp OpReplace [a''', base, c, d]) xs, OpShift a'' base' i, x])
  | {-a == a' && a' == a'' &&-} base == base' && i < length xs = OpMultiAppend a (OpApp OpReplace [a''', base, c, d]) (take i xs ++ [x] ++ drop (i + 1) xs)
improveAux _ (OpApp OpLookup [a, OpMultiAppend a' (OpApp OpReplace [a''', base, _, _]) xs, OpShift a'' base' i])
  | {-a == a' && a' == a'' &&-} base == base' && i < length xs = xs !! i
improveAux _ (OpApp OpLookup [a, OpMultiAppend a' (OpApp OpReplace [a''', base, i', x]) xs, i])
  | {-a == a' && a' == a'' &&-} i == i' = x
improveAux _ (OpApp OpReplace [a, OpMultiAppend a' (OpApp OpReplace [a''', base, i', _]) xs, i, x])
  | {-a == a' && a' == a'' &&-} i == i' = OpMultiAppend a' (OpApp OpReplace [a''', base, i, x]) xs
improveAux _ (OpShift a (OpMultiAppend a' base xs) i) =
  OpShift a base (i + length xs)
improveAux _ (OpShift a (OpApp OpReplace [a', base, _, _]) i) =
  {- a == a'-} OpShift a base i
improveAux _ (OpApp OpDrop [a, OpMultiAppend a' base xs, OpShift a'' base' 0])
  | a == a' && a' == a'' && base == base' = OpList a xs
improveAux _ (OpApp OpTake [a, base, OpShift a'' base' 0])
  | a == a'' && base == base' = base
improveAux _ (OpApp OpTake [a, OpMultiAppend a' base xs, OpShift a'' base' 0])
  | a == a' && a' == a'' && base == base' = base
improveAux _ (OpApp OpTake [a, OpMultiAppend a' (OpApp OpReplace [a''', base, _, _]) xs, OpShift a'' base' 0])
  | {-a == a' && a' == a'' &&-} base == base' = base
improveAux _ a = a

-- | Remove common constructor patterns into something more manageable.
-- Examples:
--
-- >>> Append a p X
-- MultiAppend a p [X]
-- >>> Append a (OpMultiAppend a p xs) X
-- MultiAppend a p (xs ++ [X])
--
-- Merge cons lists, and give Length an anchor point
removeSingle :: OpType -> OpType
removeSingle (OpApp OpAppend [a, OpMultiAppend a' base xs, x])
  | a == a' = OpMultiAppend a' base (xs ++ [x])
removeSingle (OpApp OpAppend [a, base, x]) =
  OpMultiAppend a base [x]
{-removeSingle (OpShift a (OpMultiAppend a' base xs) i)
  | a == a' = OpShift a base (i + length xs)-}
removeSingle (OpApp OpLen [a, base]) =
  OpShift a base 0
removeSingle (OpApp OpSucc [OpShift a b i]) =
  OpShift a b (i + 1)
removeSingle (OpApp OpNil [t]) = OpList t []
removeSingle (OpApp OpCons [a, x, OpList a' xs]) =
  {- a == a'-} OpList a (x : xs)
removeSingle a = a

improve :: KnownConstraints -> OpType -> OpType
improve uf = improveDown (improveAux uf)
-- | First improvement step, collapse simple constraint patterns.
improve' :: OpType -> OpType
improve' = improveDown removeSingle

-- | Apply the improvement function first on the arguments,
-- then on the overall type.
--
-- TODO: this should probably be a Data instance.
improveDown :: (OpType -> OpType) -> OpType -> OpType
improveDown cnt (OpApp f args) =
  case nova of
    OpApp f1 args1 ->
      if f /= f1
        then improveDown cnt (OpApp f1 args1)
        else nova
    _ -> nova
 where
  args' = map (improveDown cnt) args
  nova = cnt (OpApp f args')
improveDown cnt (OpMultiAppend x base args) =
  cnt (OpMultiAppend x base' args')
 where
  base' = improveDown cnt base
  args' = map (improveDown cnt) args
improveDown cnt (OpShift a b i) =
  cnt (OpShift a' b' i)
 where
  a' = improveDown cnt a
  b' = improveDown cnt b
improveDown cnt (OpList a xs) =
  cnt (OpList a' xs')
 where
  a' = improveDown cnt a
  xs' = map (improveDown cnt) xs
improveDown cnt a = cnt a

-- | First simplification step, given the info that we collected
-- previously, and the type constraints we need to solve for, try to
-- simplify the constraint into something that we intuitively know to hold.
--
majorSimplify :: KnownConstraints -> OpConstraintSet -> OpConstraintSet
majorSimplify info (OpConstraintSet t ch) =
  OpConstraintSet t'' (ch || changed)
 where
  t' = map phase1 t
  t'' = map (phase3 . phase2) t'
  phase1 (OpConstraint OpEquality [t1, t2]) = OpConstraint OpEquality [improve' t1, improve' t2]
  phase1 (OpConstraint OpLeq [t1, t2]) = OpConstraint OpLeq [improve' t1, improve' t2]
  phase1 (OpConstraint OpAcceptable args) = OpConstraint OpAcceptable $ map improve' args
  phase1 x = x
  phase2 (OpConstraint OpEquality [t1, t2]) = OpConstraint OpEquality [improve info t1, improve info t2]
  phase2 (OpConstraint OpLeq [t1, t2]) = OpConstraint OpLeq [improve info t1, improve info t2]
  phase2 (OpConstraint OpAcceptable args) = OpConstraint OpAcceptable $ map (improve info) args
  phase2 x = x
  phase3 (OpConstraint OpEquality [t1, OpApp OpReplace [a, t1', i, x]])
    | t1 == t1' = OpConstraint OpEquality [x, OpApp OpLookup [a, t1, i]]
  -- phase3 (OpConstraint OpLeq [OpApp OpX [], a]) = OpConstraint OpEquality [a, OpApp OpX []]
  phase3 x = x
  changed = t' /= t''
majorSimplify _ x = x

{-
 - Simplification, Part 2
 -}
-- | Simplify the constraint and generate new ones as required.
removeSimplify :: Analysis -> OpConstraint -> [OpConstraint]
removeSimplify analysis l@(OpConstraint OpAcceptable [a, b, c@(OpVar x)])
  | not (x `elemVarSet` (getVarSet analysis)) =
      case Map.lookup x (getHelper analysis) of
        Nothing -> [OpConstraint OpEquality [a, b]]
        Just OpX -> [OpConstraint OpLeq [mk OpX, a], OpConstraint OpEquality [b, mk OpN], OpConstraint OpEquality [c, mk OpX]]
        Just OpR -> [OpConstraint OpLeq [mk OpR, a], OpConstraint OpEquality [b, mk OpR], OpConstraint OpEquality [c, mk OpR]]
        _ -> [l]
removeSimplify analysis l@(OpConstraint OpAcceptable [a, b, c@(OpApp OpLookup [_, OpVar xs, i])])
  | not (xs `elemVarSet` (getVarSet analysis)) =
      case Map.lookup (xs, i) (getHelper3 analysis) of
        Nothing -> [OpConstraint OpEquality [a, b]]
        Just OpX -> [OpConstraint OpLeq [mk OpX, a], OpConstraint OpEquality [b, mk OpN], OpConstraint OpEquality [c, mk OpX]]
        Just OpR -> [OpConstraint OpLeq [mk OpR, a], OpConstraint OpEquality [b, mk OpR], OpConstraint OpEquality [c, mk OpR]]
        _ -> [l]
removeSimplify analysis (OpConstraint OpAcceptableList [a, OpVar b, OpVar c])
  | not (c `elemVarSet` (getVarSet analysis)) =
      map (\x -> OpConstraint OpAcceptable [OpApp OpLookup [accessLevel, a, x], OpApp OpLookup [accessLevel, OpVar b, x], OpApp OpLookup [accessLevel, OpVar c, x]]) indices
 where
  indicesB = fromMaybe Set.empty (Map.lookup b (getHelper2 analysis))
  indicesC = fromMaybe Set.empty (Map.lookup c (getHelper2 analysis))
  indices = Set.toList (Set.union indicesB indicesC)
  accessLevel = mk OpAccessLevel
removeSimplify analysis (OpConstraint OpLeq [a, OpApp OpLookup [_, OpVar xs, i]])
  | Just b <- Map.lookup (xs, i) (getHelper4 analysis) = [OpConstraint OpLeq [a, mk b]]
removeSimplify analysis (OpConstraint OpLeq [OpApp OpR [], OpVar v])
  | Just (OpApp OpLookup [_, OpVar xs, i]) <- Map.lookup v (getHelper7 analysis), Just OpX <- pprTraceIt "" $ Map.lookup (xs, i) (getHelper3 analysis) = []
removeSimplify analysis (OpConstraint OpEquality [a, OpApp OpLookup [_, OpVar xs, i]])
  | Nothing <- Map.lookup (xs, i) (getHelper3 analysis) = []
{-removeSimplify analysis (OpConstraint OpAcceptableList [a, b, OpVar x])
  | not (x `elemVarSet` (getVarSet analysis)) = [OpConstraint OpEquality [a, b]]-}
removeSimplify _ x = [x]

-- | Use the analysis, to generate more constraints for the given constraint
-- that we don't know how to solve, yet.
removeSimplify' :: Analysis -> OpConstraintSet -> OpConstraintSet
removeSimplify' analysis (OpConstraintSet ls ch) =
  let t = concatMap (removeSimplify analysis) ls
   in OpConstraintSet t (t /= ls || ch)

{-
 - Analysis Code, Part 1
 -}

-- | All Variables to the respective type, contains values of:
--
-- * m ~ True ==> (m, True)
-- * p@(Lookup _ _) ~ m ==> (m, p)
type Helper5 = Map Var OpType
-- | Disequality constraints, hinting that the two types are
-- not equal
type Helper8 = [(OpType, OpType)]

-- | Information record containing the existing constraints.
-- It is to note, the contents of this record are GHC version dependent.
-- Older versions of GHC (8.10.7) generate different constraints, e.g. for:
--
-- @
--   (Leq x (Lookup p n))
-- @
--
-- GHC generated the constraints:
--
-- @[Leq x c, c ~ Lookup p n]@
--
-- However, GHC 9.4.2 only generated:
--
-- @[Leq x (Lookup p n)]@
--
-- Causing important information to not be present in the analysis phase.
data KnownConstraints = KnownConstraints
  { getUnionFind :: UnionFind
  -- ^ Bags of variables occurring in 'AcceptableList'.
  -- Bags are non-overlapping, presumably.
  , equalityConstraints :: Helper5
  -- ^ Lookup constraints and definitely valid equality constraints.
  -- Constraints of the form:
  --
  -- * @p\@(Lookup p _) ~ m => (m, p)@
  -- * @m ~ True => (m, True)@
  , equalityConstraintsUnrefined :: Helper3
  -- ^ Lookup constraints to be refined later.
  , disequalityConstraints :: Helper8
  -- ^ Disequality constraints, to be used later
  }

instance Outputable KnownConstraints where
  ppr KnownConstraints {..} = hang "KnownConstraints:" 2 $
    vcat
      [ "Bags of variables" <+> ppr getUnionFind
      , "Equality constraints" <+> ppr equalityConstraints
      , "Unrefined Equality constraints" <+> ppr equalityConstraintsUnrefined
      , "Disequality constraints" <+> ppr disequalityConstraints
      ]

getInfo :: [OpConstraintSet] -> KnownConstraints
getInfo xs =
  KnownConstraints
    { getUnionFind = getUnionFindAll xs
    , equalityConstraints = helper5
    , equalityConstraintsUnrefined = getHelper6All helper5 xs
    , disequalityConstraints = getHelper8All helper5 xs
    }
 where
  helper5 = getHelper5All xs

newtype UnionFind = UnionFind [VarSet]
instance Outputable UnionFind where
  ppr (UnionFind xs) = "UnionFind {" <+> interpp'SP xs <+> "}"


instance Prelude.Semigroup UnionFind where
  -- Merges bags of variables.
  --
  -- >>> [[a, b, c], [d, e]] <> [[a, b]]
  -- [[a, b, c], [d, e]]
  --
  -- >>> [[a, b, c], [d, e]] <> [[a, e]]
  -- [[a, b, c, e], [d, e]]
  --
  (<>) uf1 (UnionFind xs) = foldr add uf1 xs
   where
    add varSet (UnionFind uf) =
      case findIndex (\varSet' -> varSet `intersectsVarSet` varSet') uf of
        Nothing -> UnionFind $ varSet : uf
        Just i ->
          let (a, b : c) = splitAt i uf
           in UnionFind $ a ++ (b `unionVarSet` varSet) : c

instance Monoid UnionFind where
  mempty = UnionFind []

-- | Find all sets of variables of Constraints such as @AcceptableList a b c@ and
-- @AcceptableList (Replace _ a _ _) b c@ and merges the variable set
-- in case of overlaps.
getUnionFindAll :: [OpConstraintSet] -> UnionFind
getUnionFindAll = constructTransform helper fold
 where
  helper (OpConstraint OpAcceptableList [OpVar a, OpVar b, OpVar c]) = UnionFind [mkVarSet [a, b, c]]
  helper (OpConstraint OpAcceptableList [OpApp OpReplace [_, OpVar a, _, _], OpVar b, OpVar c]) = UnionFind [mkVarSet [a, b, c]]
  helper _ = mempty

-- | Two variable types are compatible if they are the same
-- or they both belong to the same VarSet (e.g. bag of variables).
compatible :: UnionFind -> OpType -> OpType -> Bool
compatible _ a b
  | a == b = True
compatible (UnionFind uf) (OpVar a) (OpVar b) =
  case find (\varSet -> a `elemVarSet` varSet) uf of
    Just varSet -> b `elemVarSet` varSet
    Nothing -> False
compatible _ _ _ = False

-- | Get all constraints of the form:
--
-- * @p\@(Lookup (Var _) _) ~ m => (m, p)@
-- * @m ~ True => (m, True)@
getHelper5All :: [OpConstraintSet] -> Helper5
getHelper5All = constructTransform helper Map.unions
 where
  helper (OpConstraint OpEquality [p@(OpApp OpLookup [_, OpVar _, _]), OpVar m]) = Map.singleton m p
  helper (OpConstraint OpEquality [OpVar m, p@(OpApp OpTrue [])]) = Map.singleton m p
  helper _ = Map.empty

-- | Get constraints of the form:
--
-- * @X <= Lookup p i ==> ((p, i), X)@
-- * @R <= Lookup p i ==> ((p, i), R)@
-- * @X <= n if n ~ Lookup p i ==> ((p, i), X)@
-- * @R <= n if n ~ Lookup p i ==> ((p, i), R)@
--
-- Will be used to generate transitive constraints.
getHelper6All :: Helper5 -> [OpConstraintSet] -> Helper3
getHelper6All helper5 = constructTransform helper (Map.unionsWith maxFun)
 where
  helper (OpConstraint OpLeq [OpApp OpX [], OpApp OpLookup [_, OpVar xs, i]]) = helper' xs i OpX
  helper (OpConstraint OpLeq [OpApp OpR [], OpApp OpLookup [_, OpVar xs, i]]) = helper' xs i OpR
  helper (OpConstraint OpLeq [OpApp OpX [], OpVar v])
    | Just (OpApp OpLookup [_, OpVar xs, i]) <- Map.lookup v helper5 = helper' xs i OpX
  helper (OpConstraint OpLeq [OpApp OpR [], OpVar v])
    | Just (OpApp OpLookup [_, OpVar xs, i]) <- Map.lookup v helper5 = helper' xs i OpR
  helper _ = Map.empty
  helper' xs i y = Map.singleton (xs, i) y

-- | Collect all inequality constraints of the form:
--
-- * @a /~ b ~ True ==> [(a, b), (b, a)]@
-- * @a /~ b ~ c if c ~ True ==> [(a, b), (b, a)]@
getHelper8All :: Helper5 -> [OpConstraintSet] -> Helper8
getHelper8All helper5 = constructTransform helper concat
 where
  helper (OpConstraint OpEquality [OpApp OpDisequality [_, a, b], OpApp OpTrue []]) = [(a, b), (b, a)]
  helper (OpConstraint OpEquality [OpApp OpDisequality [_, a, b], OpVar v])
    | Just (OpApp OpTrue []) <- Map.lookup v helper5 = [(a, b), (b, a)]
  helper _ = []

{-
 - Analysis Code, Part 2
 -}

-- | Transform the set of constraints into a single element.
constructTransform :: (OpConstraint -> a) -> ([a] -> a) -> ([OpConstraintSet] -> a)
constructTransform transform union = mapUnion transform'
 where
  transform' (OpConstraintSet ys _) = mapUnion transform ys
  mapUnion f = union . map f

type Helper = Map Var OpFun
type Helper2 = Map Var (Set OpType)
type Helper3 = Map (Var, OpType) OpFun

data Analysis = Analysis
  { getHelper :: Helper
  -- ^ (x, a) for every Leq a x, for concrete a, var x
  , getHelper2 :: Helper2
  -- ^ (xs, is) where Leq a (Lookup xs i) for concrete a, var xs, for each i in is
  , getHelper3 :: Helper3
  -- ^ ((xs, i), a) for every Leq a (Lookup xs i), for concrete a, variable xs
  , getHelper4 :: Helper3
  -- ^ ((xs, i), a) for every (Lookup xs i ~ a), for concrete a, variable xs
  , getHelper7 :: Helper5
  -- ^ Constraints of the form:
  --
  -- * @p\@(Lookup p _) ~ m => (m, p)@
  -- * @m ~ True => (m, True)@
  -- TODO: isn't that kind of the same as getHelper4?
  , getVarSet :: VarSet
  -- ^ Free variables
  }

instance Outputable Analysis where
  ppr Analysis {..} =
    vcat
      [ "getHelper" <+> ppr getHelper
      , "getHelper2" <+> ppr getHelper2
      , "getHelper3" <+> ppr getHelper3
      , "getHelper4" <+> ppr getHelper4
      , "getHelper7" <+> ppr getHelper7
      , "getVarSet (free variables)" <+> ppr getVarSet
      ]

getAnalysis :: [OpConstraintSet] -> Analysis
getAnalysis xs =
  Analysis
    { getHelper = getHelperAll xs
    , getHelper2 = getHelper2All xs
    , getHelper3 = getHelper6All helper5 xs
    , getHelper4 = getHelper4All xs
    , getHelper7 = helper5
    , getVarSet = freeVarsAll xs
    }
 where
  helper5 = getHelper5All xs

maxFun OpX _ = OpX
maxFun _ OpX = OpX
maxFun _ _ = OpR

getHelperAll :: [OpConstraintSet] -> Helper
getHelperAll = constructTransform helper (Map.unionsWith maxFun)
 where
  helper (OpConstraint OpLeq [OpApp OpX [], OpVar a]) = Map.singleton a OpX
  helper (OpConstraint OpLeq [OpApp OpR [], OpVar a]) = Map.singleton a OpR
  helper _ = Map.empty

getHelper2All :: [OpConstraintSet] -> Helper2
getHelper2All = constructTransform helper (Map.unionsWith Set.union)
 where
  helper (OpConstraint OpLeq [OpApp OpX [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton xs (Set.singleton i)
  helper (OpConstraint OpLeq [OpApp OpR [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton xs (Set.singleton i)
  helper _ = Map.empty

getHelper3All :: [OpConstraintSet] -> Helper3
getHelper3All = constructTransform helper (Map.unionsWith maxFun)
 where
  helper (OpConstraint OpLeq [OpApp OpX [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton (xs, i) OpX
  helper (OpConstraint OpLeq [OpApp OpR [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton (xs, i) OpR
  helper _ = Map.empty

getHelper4All :: [OpConstraintSet] -> Helper3
getHelper4All = constructTransform helper (Map.unions)
 where
  helper (OpConstraint OpEquality [OpApp OpX [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton (xs, i) OpX
  helper (OpConstraint OpEquality [OpApp OpR [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton (xs, i) OpR
  helper (OpConstraint OpEquality [OpApp OpN [], OpApp OpLookup [_, OpVar xs, i]]) = Map.singleton (xs, i) OpN
  helper _ = Map.empty

freeVarsAll :: [OpConstraintSet] -> VarSet
freeVarsAll = constructTransform helper unionVarSets
 where
  helper (OpConstraint OpLeq [OpApp OpX [], OpVar _]) = emptyVarSet
  helper (OpConstraint OpLeq [OpApp OpR [], OpVar _]) = emptyVarSet
  helper (OpConstraint OpLeq [OpApp OpX [], OpApp OpLookup [_, OpVar xs, i]]) = emptyVarSet
  helper (OpConstraint OpLeq [OpApp OpR [], OpApp OpLookup [_, OpVar xs, i]]) = emptyVarSet
  helper (OpConstraint OpAcceptable [a, b, OpApp OpLookup [_, OpVar _, i]]) = mapUnionVarSet freeVars [a, b, i]
  helper (OpConstraint OpAcceptable [a, b, OpVar _]) = mapUnionVarSet freeVars [a, b]
  helper (OpConstraint OpAcceptableList [a, b, OpVar _]) = mapUnionVarSet freeVars [a, b]
  helper (OpConstraint OpAcceptable [a, b, c]) = mapUnionVarSet freeVars [a, b, c]
  helper (OpConstraint _ args) = mapUnionVarSet freeVars args

  freeVars (OpVar var) = unitVarSet var
  freeVars (OpApp _ args) = mapUnionVarSet freeVars args
  freeVars (OpLift _) = emptyVarSet
  freeVars (OpMultiAppend x y xs) = mapUnionVarSet freeVars (x : y : xs)
  freeVars (OpShift x y _) = mapUnionVarSet freeVars [x, y]
  freeVars (OpList x xs) = mapUnionVarSet freeVars (x : xs)

{-
 - Bootstrapping Code
 -}

solve :: State -> EvBindsVar -> [Ct] -> [Ct] -> TcPluginM TcPluginSolveResult
solve st _evidence given wanted = do
  -- Translate the wanted constraints to something we can understand
  let (old, cts') = unzip . mapMaybe (keepMaybe (handle st)) $ wanted
  -- Get our already solved constraints that we know how to handle
  let test = mapMaybe (handle st) $ given
  -- Preprocess the information we have into a record of relevant infos
  let relevant = getInfo (cts' ++ test)
  tcPluginTrace "relevant" (ppr relevant)
  tcPluginTrace "what is given" (interppSP test)
  tcPluginTrace "what is requested" (interppSP cts')
  tcPluginTrace "what is additional" (interppSP (map (ctLocSpan . ctLoc) wanted))
  -- simplify the constraints we want into something more manageable
  let simplifiedWantedCnstr = map (majorSimplify relevant . align) cts'
  tcPluginTrace "simplified wanted" (interppSP simplifiedWantedCnstr)
  let analysis = getAnalysis (simplifiedWantedCnstr ++ test)
  tcPluginTrace "analysis result" (ppr analysis)
  let newCts = map (removeSimplify' analysis) simplifiedWantedCnstr
  tcPluginTrace "simplified constraints" (ppr newCts)
  -- Only translate constraints that have actually changed
  let final = filter (\(_a, b) -> hasChanged b) $ zip old newCts
  -- translate with proves
  let res = map (turnIntoCt st) final
  if not (null res)
    then do
      -- tcPluginIO $ putStrLn "---here---"
      -- tcPluginIO $ putStrLn $ "what is proven:\n " ++ (showSDocUnsafe (interppSP (map fst final)))
      -- tcPluginIO $ putStrLn $ "what is wanted:\n " ++ (showSDocUnsafe (interppSP (map snd final)))
      b <- concat <$> mapM (makeIntoCt st) final
      -- tcPluginIO $ putStrLn $ showSDocUnsafe $ interppSP (mapMaybe (handle st) given)
      -- c <- (mapM testSimplify' . mapMaybe (handle st)) $ wanted
      -- tcPluginIO $ putStrLn $ "what is additional:\n " ++ (showSDocUnsafe (interppSP (map (ctLocSpan . ctLoc) (map fst final))))
      -- tcPluginIO $ putStrLn $ showSDocUnsafe $ interppSP c
      -- tcPluginIO $ putStrLn $ showSDocUnsafe $ interppSP (map majorSimplify . mapMaybe (handle st) $ wanted)
      return $ TcPluginOk res b
    else return $ TcPluginOk [] []

plugin :: Plugin
plugin = defaultPlugin{tcPlugin = const (Just myPlugin)}

myPlugin :: TcPlugin
myPlugin =
  TcPlugin
    { tcPluginInit = buildState
    , tcPluginSolve = solve
    , tcPluginStop = stop
    , tcPluginRewrite = \_ -> emptyUFM
    }

stop :: State -> TcPluginM ()
stop _ = do
  return ()
