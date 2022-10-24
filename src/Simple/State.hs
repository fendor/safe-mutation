{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}

module Simple.State where

import Utils
import Prelude hiding (Monad (..))
import PrelNames (nullAddrIdKey)

data StateS s p q x where
  PutS :: s -> StateS s p p ()
  GetS :: StateS s p p s

data StateG s p p' q' q x' x where
  LocalG :: (s -> s) -> StateG s p p' q' q x x

getS :: IProg (StateS s) g p p s
getS = Impure GetS return

putS :: s -> IProg (StateS s) g p p ()
putS s = Impure (PutS s) return

localG :: (s -> s) -> IProg f (StateG s) q r a -> IProg f (StateG s) p r a
localG f prog = Scope (LocalG f) prog return

runState :: s -> IProg (StateS s) (StateG s) p q a -> (s, a)
runState s (Pure a) = (s, a)
runState s (Impure GetS k) = runState s (k s)
runState _s (Impure (PutS s') k) = runState s' (k ())
runState s (Scope (LocalG f) prog k) = runState s (k x)
 where
  (_, x) = runState (f s) prog

stateExample :: IProg (StateS Int) (StateG Int) p p String
stateExample = do
  i <- getS
  putS (i + i)
  return $ show i

stateWithLocal :: IProg (StateS Int) (StateG Int) p p String
stateWithLocal = do
  n <- getS @Int
  x <- localG (+ n) stateExample
  return $ x ++ ", initial: " ++ show n

ambiguityExample :: IProg (StateS Int) a p p ()
ambiguityExample = do
  _i <- getS
  return ()

-- typeExperiment :: Sem (StateS Int :+: (StateS String :+: IIdentity)) '((), '((), ())) '((), '((), ())) String
-- typeExperiment :: Sem (StateS Int :+: StateS String) '(p, s) '(p, s) [Char]
typeExperiment :: Sem (StateS Int :+: (StateS String :+: IIdentity)) '(sl1, '(sl2, sr)) '(sl1, '(sl2, sr)) [Char]
typeExperiment = do
  i <- getNS1 @Int
  putNS2 (show i)
  return "test"

-- getNS1 :: Sem (StateS i :+: StateS s :+: IIdentity) '(p, q) '(p, q) i
getNS1 :: Sem (StateS a :+: f2) '(sl, sr) '(sl, sr) a
getNS1 = Op (Inl GetS) (IKleisliTupled return)

getNS1' :: Sem (StateS a :+: (StateS c :+: IIdentity)) '(sl, '(sl2, sr)) '(sl, '(sl2, sr)) a
getNS1' = Op (Inl GetS) (IKleisliTupled return)

-- putNS2 :: i -> Sem (s :+: StateS i :+: effs) '(e, '(p, u)) '(e, '(p, u)) ()
putNS2 :: s -> Sem (f1 :+: (StateS s :+: f2)) '(sl, '(sl2, sr)) '(sl, '(sl2, sr)) ()
putNS2 i = Op (Inr (Inl $ PutS i)) (IKleisliTupled return)

-- putNS2' :: s -> Sem (StateS i :+: StateS s :+: IIdentity) '(sl, '(sl2, sr)) '(sl, '(sl2, sr)) ()
putNS2' :: s -> Sem (f1 :+: (StateS s :+: f2)) '(sl, '(sl2, sr)) '(sl, '(sl2, sr)) ()
putNS2' i = Op (Inr $ Inl $ PutS i) (IKleisliTupled return)

simpleState :: Sem (StateS Int :+: IIdentity) '((), ()) '((), ()) Int
simpleState = return 0

foo = Simple.State.runPure (\case
  GetS -> 5
  PutS s -> ()) typeExperiment

-- runExp :: (String, (Int, String))
runExp = run $ runStateE "test" $ runStateE 10 typeExperiment

run :: Sem IIdentity p q a -> a
run (Value a) = a
run (Op cmd k) = run $ runIKleisliTupled k (runIdentity cmd)

-- >>> :t runIKleisliTupled (undefined :: IKleisliTupled (Sem (StateS s : effs)) '((p, q1), s) '((p, v), a))
-- runIKleisliTupled (undefined :: IKleisliTupled (Sem (StateS s : effs)) '((p, q1), s) '((p, v), a)) :: s -> Sem (StateS s : effs) (p, q1) (p, v) a
--
--
runStateE ::
  -- forall s a effs p u v.
  s ->
  Sem (StateS s :+: effs) '(p, u) '(p, v) a ->
  Sem effs u v (s, a)
runStateE s (Value a) = Value (s, a)
runStateE s (Op (Inl GetS) k) = runStateE s (runIKleisliTupled k s)
runStateE _s (Op (Inl (PutS s')) k) = runStateE s' (runIKleisliTupled k ())
runStateE s (Op (Inr other) k) = Op other $
  IKleisliTupled $
    \x -> runStateE s $ runIKleisliTupled k x

runPure ::
  (forall p q b. eff p q b -> b) ->
  Sem (eff :+: effs) '(s, ps) '(t, qs) a ->
  Sem effs ps qs a
runPure _ (Value a) = Value a
runPure f (Op (Inr cmd) q) = Op cmd k
 where
  k = IKleisliTupled $ \a -> Simple.State.runPure f $ runIKleisliTupled q a
runPure f (Op (Inl cmd) q) = Simple.State.runPure f $ runIKleisliTupled q (f cmd)
