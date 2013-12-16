{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
-- | Effects which fail.
module Control.Eff.Fail( Fail
                       , die
                       , mayFail
                       , runFail
                       , ignoreFail
                       , onFail
                       , excToFail
                       , failToExc
                       ) where

import Control.Monad
import Data.Typeable

import Control.Eff
import Control.Eff.Exception

-- | 'Fail' represents effects which can fail. This is akin to the Maybe monad.
data Fail v = Fail
  deriving (Functor, Typeable)

-- | Makes an effect fail, preventing future effects from happening.
die :: Member Fail r
    => Eff r a
die = send (const (inj Fail))
{-# INLINE die #-}

-- | Lift a maybe into the 'Fail' effect, causing failure if it's 'Nothing'.
mayFail :: Member Fail r
        => Maybe a
        -> Eff r a
mayFail Nothing  = die
mayFail (Just x) = return x
{-# INLINE mayFail #-}

-- | Runs a failable effect, such that failed computation return 'Nothing', and
--   'Just' the return value on success.
runFail :: Eff (Fail :> r) a
        -> Eff r (Maybe a)
runFail m = loop (admin m)
 where
  loop (Val x) = return (Just x)
  loop (E u)   = handleRelay u loop (const (return Nothing))
{-# INLINE runFail #-}

-- | Given a computation to run on failure, and a computation that can fail,
--   this function runs the computation that can fail, and if it fails, gets
--   the return value from the other computation. This hides the fact that a
--   failure even happened, and returns a default value for when it does.
onFail :: Eff r a           -- ^ The computation to run on failure.
       -> Eff (Fail :> r) a -- ^ The computation which can fail.
       -> Eff r a
onFail sideshow mainEvent = do
  r <- runFail mainEvent
  case r of
    Nothing -> sideshow
    Just y  -> return y
{-# INLINE onFail #-}

-- | Ignores a failure event. Since the event can fail, you cannot inspect its
--   return type, because it has none on failure. To inspect it, use 'runFail'.
ignoreFail :: Eff (Fail :> r) a
           -> Eff r ()
ignoreFail = onFail (return ()) . void
{-# INLINE ignoreFail #-}

excToFail :: (Typeable e, Member Fail r) => Eff (Exc e :> r) a -> Eff r a
excToFail e = runExc e >>= either (\_-> die) return
{-# INLINE excToFail #-}

failToExc :: (Typeable e, Member (Exc e) r) => e -> Eff (Fail :> r) a -> Eff r a
failToExc e m = runFail m >>= maybe (throwExc e) return
{-# INLINE failToExc #-}