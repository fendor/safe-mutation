{-# LANGUAGE QualifiedDo #-}

module Simple.State where

import Data.Proxy
import Data.Typeable
import GHC.TypeLits
import Unsafe.Coerce
import Utils
import qualified Utils as I
import Prelude hiding (Monad (..))

data StateS s x where
    PutS :: s -> StateS s ()
    GetS :: StateS s s
    deriving (Typeable)

getS ::
    (SMember (StateS s) effs) =>
    IProg effs f g ps ps s
getS = Impure (inj GetS) emptyCont

putS ::
    ( SMember (StateS s) effs
    ) =>
    s ->
    IProg effs f g ps ps ()
putS s = Impure (inj $ PutS s) emptyCont

runState ::
    s ->
    IProg (StateS s : effs) IIdentity IVoid ps qs a ->
    IProg effs IIdentity IVoid ps qs (s, a)
runState s (Value a) = I.return (s, a)
runState s (Impure (OHere GetS) k) = runState s (runIKleisliTupled k s)
runState _s (Impure (OHere (PutS s')) k) = runState s' (runIKleisliTupled k ())
runState s (Impure (OThere cmd) k) = Impure cmd $ IKleisliTupled (runState s . runIKleisliTupled k)
runState _ (ScopeT _ _) = error "Impossible, Scope node must never be created"

stateExample ::
    (SMember (StateS Int) effs) =>
    IProg effs f g ps ps String
stateExample = I.do
    i <- getS @Int
    putS (i + i)
    I.return $ show i

-- stateWithLocal ::
--   ( SMember (StateS Int) effs ps ps
--   , g ~ StateG Int
--   ) =>
--   IProg effs g ps ps String
-- stateWithLocal = I.do
--   n <- getS @Int
--   x <- modifyG (+ n) stateExample
--   return $ x ++ ", initial: " ++ show n

-- -- ambiguityExample :: forall effs ps qs g . SMember (StateS Int) effs ps qs => IProg effs g ps qs Int

-- ambiguityExample ::
--   (SMember (StateS Int) effs ps ps) =>
--   IProg effs g ps ps Int
-- ambiguityExample = I.do
--   i <- getS
--   i2 <- getS
--   putS (i + i2)
--   I.return $ i + i2

-- moreExamples ::
--   ( SMember (StateS Int) effs ps ps
--   , SMember (StateS String) effs ps ps
--   ) =>
--   IProg effs g ps ps Int
-- moreExamples = I.do
--   i <- getS -- :: forall js . IProg effs g ps js Int
--   i2 <- getS -- :: forall js . IProg effs g js qs Int
--   (m :: String) <- getS
--   putS (m ++ reverse m)
--   _ <- ambiguityExample
--   I.return $ i + i2

-- -- runner :: IProg '[IIdentity] IVoid '[()] '[()] (Int, String)
-- runner = runState @() @() "mama" $ runStateG @() @() (5 :: Int) moreExamples
