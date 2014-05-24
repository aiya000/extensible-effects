{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, DeriveFunctor #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE CPP #-}

-- | Original work available at <http://okmij.org/ftp/Haskell/extensible/Eff.hs>.
-- This module implements extensible effects as an alternative to monad transformers,
-- as described in <http://okmij.org/ftp/Haskell/extensible/exteff.pdf>.
--
-- Extensible Effects are implemented as typeclass constraints on an Eff[ect] datatype.
-- A contrived example is:
--
-- > {-# LANGUAGE FlexibleContexts #-}
-- > import Control.Eff
-- > import Control.Eff.Lift
-- > import Control.Eff.State
-- > import Control.Monad (void)
-- > import Data.Typeable
-- >
-- > -- Write the elements of a list of numbers, in order.
-- > writeAll :: (Typeable a, Member (Writer a) e)
-- >          => [a]
-- >          -> Eff e ()
-- > writeAll = mapM_ putWriter
-- >
-- > -- Add a list of numbers to the current state.
-- > sumAll :: (Typeable a, Num a, Member (State a) e)
-- >        => [a]
-- >        -> Eff e ()
-- > sumAll = mapM_ (onState . (+))
-- >
-- > -- Write a list of numbers and add them to the current state.
-- > writeAndAdd :: (Member (Writer Integer) e, Member (State Integer) e)
-- >             => [Integer]
-- >             -> Eff e ()
-- > writeAndAdd l = do
-- >     writeAll l
-- >     sumAll l
-- >
-- > -- Sum a list of numbers.
-- > sumEff :: (Num a, Typeable a) => [a] -> a
-- > sumEff l = let (s, ()) = run $ runState 0 $ sumAll l
-- >            in s
-- >
-- > -- Safely get the last element of a list.
-- > -- Nothing for empty lists; Just the last element otherwise.
-- > lastEff :: Typeable a => [a] -> Maybe a
-- > lastEff l = let (a, ()) = run $ runWriter $ writeAll l
-- >             in a
-- >
-- > -- Get the last element and sum of a list
-- > lastAndSum :: (Typeable a, Num a) => [a] -> (Maybe a, a)
-- > lastAndSum l = let (lst, (total, ())) = run $ runWriter $ runState 0 $ writeAndAdd l
-- >                in (lst, total)
module Control.Eff(
                    Eff
                  , VE (..)
                  , Member
                  , SetMember
                  , Union
                  , (:>)
                  , inj
                  , prj
                  , prjForce
                  , decomp
                  , send
                  , admin
                  , run
                  , interpose
                  , handleRelay
                  , unsafeReUnion
                  ) where

import Control.Applicative (Applicative (..), (<$>))
import Control.Monad (ap)
import Data.OpenUnion1
import Data.Typeable

#if MIN_VERSION_base(4,7,0)
#define Typeable1 Typeable
#endif

-- | A `VE` is either a value, or an effect of type @`Union` r@ producing another `VE`.
-- The result is that a `VE` can produce an arbitrarily long chain of @`Union` r@
-- effects, terminated with a pure value.
data VE r w = Val w | E !(Union r (VE r w))
  deriving Typeable

fromVal :: VE r w -> w
fromVal (Val w) = w
fromVal _ = error "extensible-effects: fromVal was called on a non-terminal effect."
{-# INLINE fromVal #-}

-- | Basic datatype returned by all computations with extensible effects.
-- The type @r@ is the type of effects that can be handled,
-- and @a@ is the type of value that is returned.
newtype Eff r a = Eff { runEff :: forall w. (a -> VE r w) -> VE r w }
  deriving Typeable

instance Functor (Eff r) where
    fmap f m = Eff $ \k -> runEff m (k . f)
    {-# INLINE fmap #-}

instance Applicative (Eff r) where
    pure = return
    (<*>) = ap

instance Monad (Eff r) where
    return x = Eff $ \k -> k x
    {-# INLINE return #-}

    m >>= f = Eff $ \k -> runEff m (\v -> runEff (f v) k)
    {-# INLINE (>>=) #-}

-- | Given a method of turning requests into results,
-- we produce an effectful computation.
send :: (forall w. (a -> VE r w) -> Union r (VE r w)) -> Eff r a
send f = Eff (E . f)
{-# INLINE send #-}

-- | Tell an effectful computation that you're ready to start running effects
-- and return a value.
admin :: Eff r w -> VE r w
admin (Eff m) = m Val
{-# INLINE admin #-}

-- | Get the result from a pure computation.
run :: Eff () w -> w
run = fromVal . admin
{-# INLINE run #-}

-- the other case is unreachable since () has no constructors
-- Therefore, run is a total function if m Val terminates.

-- | Given a request, either handle it or relay it.
handleRelay :: Typeable1 t
            => Union (t :> r) v -- ^ Request
            -> (v -> Eff r a)   -- ^ Relay the request
            -> (t v -> Eff r a) -- ^ Handle the request of type t
            -> Eff r a
handleRelay u loop h = either passOn h $ decomp u
  where passOn u' = send (<$> u') >>= loop
  -- perhaps more efficient:
  -- passOn u' = send (\k -> fmap (\w -> runEff (loop w) k) u')
{-# INLINE handleRelay #-}

-- | Given a request, either handle it or relay it. Both the handler
-- and the relay can produce the same type of request that was handled.
interpose :: (Typeable1 t, Functor t, Member t r)
          => Union r v
          -> (v -> Eff r a)
          -> (t v -> Eff r a)
          -> Eff r a
interpose u loop h = maybe (send (<$> u) >>= loop) h $ prj u
{-# INLINE interpose #-}
