{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
# if MIN_VERSION_array(0,4,0)
{-# LANGUAGE Safe #-}
# endif
#endif
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.DeepSeq
-- Copyright   :  (c) The University of Glasgow 2001-2009
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  stable
-- Portability :  portable
--
-- This module provides an overloaded function, 'deepseq', for fully
-- evaluating data structures (that is, evaluating to \"Normal Form\").
--
-- A typical use is to prevent resource leaks in lazy IO programs, by
-- forcing all characters from a file to be read. For example:
--
-- > import System.IO
-- > import Control.DeepSeq
-- >
-- > main = do
-- >     h <- openFile "f" ReadMode
-- >     s <- hGetContents h
-- >     s `deepseq` hClose h
-- >     return s
--
-- 'deepseq' differs from 'seq' as it traverses data structures deeply,
-- for example, 'seq' will evaluate only to the first constructor in
-- the list:
--
-- > > [1,2,undefined] `seq` 3
-- > 3
--
-- While 'deepseq' will force evaluation of all the list elements:
--
-- > > [1,2,undefined] `deepseq` 3
-- > *** Exception: Prelude.undefined
--
-- Another common use is to ensure any exceptions hidden within lazy
-- fields of a data structure do not leak outside the scope of the
-- exception handler, or to force evaluation of a data structure in one
-- thread, before passing to another thread (preventing work moving to
-- the wrong threads).
--
-- /Since: 1.1.0.0/
module Control.DeepSeq (
     deepseq, ($!!), force,
     NFData(..),
  ) where

import Control.Applicative
import Control.Concurrent ( ThreadId )
import Data.Int
import Data.Word
import Data.Ratio
import Data.Complex
import Data.Array
import Data.Fixed
import Data.Version
import Data.Monoid
import Data.Unique ( Unique )
import Foreign.C.Types
import System.Mem.StableName ( StableName )

#if MIN_VERSION_base(4,6,0)
import Data.Ord ( Down(Down) )
#endif

#if MIN_VERSION_base(4,7,0)
import Data.Proxy ( Proxy(Proxy) )
#endif

#if MIN_VERSION_base(4,8,0)
import Data.Functor.Identity ( Identity(..) )
-- NB: Data.Typeable.Internal is "Trustworthy" only starting w/ base-4.8
import Data.Typeable.Internal ( TypeRep(..), TyCon(..) )
import Data.Void ( Void, absurd )
import Numeric.Natural ( Natural )
#endif

#if __GLASGOW_HASKELL__ >= 702
import GHC.Fingerprint.Type ( Fingerprint(..) )
import GHC.Generics

-- | Hidden internal type-class
class GNFData f where
  grnf :: f a -> ()

instance GNFData V1 where
  grnf = error "Control.DeepSeq.rnf: uninhabited type"

instance GNFData U1 where
  grnf U1 = ()

instance NFData a => GNFData (K1 i a) where
  grnf = rnf . unK1
  {-# INLINEABLE grnf #-}

instance GNFData a => GNFData (M1 i c a) where
  grnf = grnf . unM1
  {-# INLINEABLE grnf #-}

instance (GNFData a, GNFData b) => GNFData (a :*: b) where
  grnf (x :*: y) = grnf x `seq` grnf y
  {-# INLINEABLE grnf #-}

instance (GNFData a, GNFData b) => GNFData (a :+: b) where
  grnf (L1 x) = grnf x
  grnf (R1 x) = grnf x
  {-# INLINEABLE grnf #-}
#endif

infixr 0 $!!

-- | 'deepseq': fully evaluates the first argument, before returning the
-- second.
--
-- The name 'deepseq' is used to illustrate the relationship to 'seq':
-- where 'seq' is shallow in the sense that it only evaluates the top
-- level of its argument, 'deepseq' traverses the entire data structure
-- evaluating it completely.
--
-- 'deepseq' can be useful for forcing pending exceptions,
-- eradicating space leaks, or forcing lazy I/O to happen.  It is
-- also useful in conjunction with parallel Strategies (see the
-- @parallel@ package).
--
-- There is no guarantee about the ordering of evaluation.  The
-- implementation may evaluate the components of the structure in
-- any order or in parallel.  To impose an actual order on
-- evaluation, use 'pseq' from "Control.Parallel" in the
-- @parallel@ package.
--
-- /Since: 1.1.0.0/
deepseq :: NFData a => a -> b -> b
deepseq a b = rnf a `seq` b

-- | the deep analogue of '$!'.  In the expression @f $!! x@, @x@ is
-- fully evaluated before the function @f@ is applied to it.
--
-- /Since: 1.2.0.0/
($!!) :: (NFData a) => (a -> b) -> a -> b
f $!! x = x `deepseq` f x

-- | a variant of 'deepseq' that is useful in some circumstances:
--
-- > force x = x `deepseq` x
--
-- @force x@ fully evaluates @x@, and then returns it.  Note that
-- @force x@ only performs evaluation when the value of @force x@
-- itself is demanded, so essentially it turns shallow evaluation into
-- deep evaluation.
--
-- /Since: 1.2.0.0/
force :: (NFData a) => a -> a
force x = x `deepseq` x

-- | A class of types that can be fully evaluated.
--
-- /Since: 1.1.0.0/
class NFData a where
    -- | 'rnf' should reduce its argument to normal form (that is, fully
    -- evaluate all sub-components), and then return '()'.
    --
    -- === 'Generic' 'NFData' deriving
    --
    -- Starting with GHC 7.2, you can automatically derive instances
    -- for types possessing a 'Generic' instance.
    --
    -- > {-# LANGUAGE DeriveGeneric #-}
    -- >
    -- > import GHC.Generics (Generic)
    -- > import Control.DeepSeq
    -- >
    -- > data Foo a = Foo a String
    -- >              deriving (Eq, Generic)
    -- >
    -- > instance NFData a => NFData (Foo a)
    -- >
    -- > data Colour = Red | Green | Blue
    -- >               deriving Generic
    -- >
    -- > instance NFData Colour
    --
    -- Starting with GHC 7.10, the example above can be written more
    -- concisely by enabling the new @DeriveAnyClass@ extension:
    --
    -- > {-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
    -- >
    -- > import GHC.Generics (Generic)
    -- > import Control.DeepSeq
    -- >
    -- > data Foo a = Foo a String
    -- >              deriving (Eq, Generic, NFData)
    -- >
    -- > data Colour = Red | Green | Blue
    -- >               deriving (Generic, NFData)
    -- >
    --
    -- === Compatibility with previous @deepseq@ versions
    --
    -- Prior to version 1.4.0.0, the default implementation of the 'rnf'
    -- method was defined as
    --
    -- @'rnf' a = 'seq' a ()@
    --
    -- However, starting with @deepseq-1.4.0.0@, the default
    -- implementation is based on @DefaultSignatures@ allowing for
    -- more accurate auto-derived 'NFData' instances. If you need the
    -- previously used exact default 'rnf' method implementation
    -- semantics, use
    --
    -- > instance NFData Colour where rnf x = seq x ()
    --
    -- or alternatively
    --
    -- > {-# LANGUAGE BangPatterns #-}
    -- > instance NFData Colour where rnf !_ = ()
    --
    rnf :: a -> ()

#if __GLASGOW_HASKELL__ >= 702
    default rnf :: (Generic a, GNFData (Rep a)) => a -> ()
    rnf = grnf . from
#endif

instance NFData Int      where rnf !_ = ()
instance NFData Word     where rnf !_ = ()
instance NFData Integer  where rnf !_ = ()
instance NFData Float    where rnf !_ = ()
instance NFData Double   where rnf !_ = ()

instance NFData Char     where rnf !_ = ()
instance NFData Bool     where rnf !_ = ()
instance NFData ()       where rnf !_ = ()

instance NFData Int8     where rnf !_ = ()
instance NFData Int16    where rnf !_ = ()
instance NFData Int32    where rnf !_ = ()
instance NFData Int64    where rnf !_ = ()

instance NFData Word8    where rnf !_ = ()
instance NFData Word16   where rnf !_ = ()
instance NFData Word32   where rnf !_ = ()
instance NFData Word64   where rnf !_ = ()

#if MIN_VERSION_base(4,7,0)
-- |/Since: 1.4.0.0/
instance NFData (Proxy a) where rnf Proxy = ()
#endif

#if MIN_VERSION_base(4,8,0)
-- |/Since: 1.4.0.0/
instance NFData a => NFData (Identity a) where
    rnf = rnf . runIdentity

-- | Defined as @'rnf' = 'absurd'@.
--
-- /Since: 1.4.0.0/
instance NFData Void where
    rnf = absurd

-- |/Since: 1.4.0.0/
instance NFData Natural  where rnf !_ = ()
#endif

-- |/Since: 1.3.0.0/
instance NFData (Fixed a) where rnf !_ = ()

-- |This instance is for convenience and consistency with 'seq'.
-- This assumes that WHNF is equivalent to NF for functions.
--
-- /Since: 1.3.0.0/
instance NFData (a -> b) where rnf !_ = ()

--Rational and complex numbers.

#if __GLASGOW_HASKELL__ >= 711
instance NFData a => NFData (Ratio a) where
#else
instance (Integral a, NFData a) => NFData (Ratio a) where
#endif
  rnf x = rnf (numerator x, denominator x)

#if MIN_VERSION_base(4,4,0)
instance (NFData a) => NFData (Complex a) where
#else
instance (RealFloat a, NFData a) => NFData (Complex a) where
#endif
  rnf (x:+y) = rnf x `seq`
               rnf y `seq`
               ()

instance NFData a => NFData (Maybe a) where
    rnf Nothing  = ()
    rnf (Just x) = rnf x

instance (NFData a, NFData b) => NFData (Either a b) where
    rnf (Left x)  = rnf x
    rnf (Right y) = rnf y

-- |/Since: 1.3.0.0/
instance NFData Data.Version.Version where
    rnf (Data.Version.Version branch tags) = rnf branch `seq` rnf tags

instance NFData a => NFData [a] where
    rnf [] = ()
    rnf (x:xs) = rnf x `seq` rnf xs

-- |/Since: 1.4.0.0/
instance NFData a => NFData (ZipList a) where
    rnf = rnf . getZipList

-- |/Since: 1.4.0.0/
instance NFData a => NFData (Const a b) where
    rnf = rnf . getConst

#if __GLASGOW_HASKELL__ >= 711
instance (NFData a, NFData b) => NFData (Array a b) where
#else
instance (Ix a, NFData a, NFData b) => NFData (Array a b) where
#endif
    rnf x = rnf (bounds x, Data.Array.elems x)

#if MIN_VERSION_base(4,6,0)
-- |/Since: 1.4.0.0/
instance NFData a => NFData (Down a) where
    rnf (Down x) = rnf x
#endif

-- |/Since: 1.4.0.0/
instance NFData a => NFData (Dual a) where
    rnf = rnf . getDual

-- |/Since: 1.4.0.0/
instance NFData a => NFData (First a) where
    rnf = rnf . getFirst

-- |/Since: 1.4.0.0/
instance NFData a => NFData (Last a) where
    rnf = rnf . getLast

-- |/Since: 1.4.0.0/
instance NFData Any where rnf = rnf . getAny

-- |/Since: 1.4.0.0/
instance NFData All where rnf = rnf . getAll

-- |/Since: 1.4.0.0/
instance NFData a => NFData (Sum a) where
    rnf = rnf . getSum

-- |/Since: 1.4.0.0/
instance NFData a => NFData (Product a) where
    rnf = rnf . getProduct

-- |/Since: 1.4.0.0/
instance NFData (StableName a) where
    rnf !_ = () -- assumes `data StableName a = StableName (StableName# a)`

-- |/Since: 1.4.0.0/
instance NFData ThreadId where
    rnf !_ = () -- assumes `data ThreadId = ThreadId ThreadId#`

-- |/Since: 1.4.0.0/
instance NFData Unique where
    rnf !_ = () -- assumes `newtype Unique = Unique Integer`

#if MIN_VERSION_base(4,8,0)
-- | __NOTE__: Only defined for @base-4.8.0.0@ and later
--
-- /Since: 1.4.0.0/
instance NFData TypeRep where
    rnf (TypeRep _ tycon kis tyrep) = rnf tycon `seq` rnf kis `seq` rnf tyrep

-- | __NOTE__: Only defined for @base-4.8.0.0@ and later
--
-- /Since: 1.4.0.0/
instance NFData TyCon where
    rnf (TyCon _ tcp tcm tcn) = rnf tcp `seq` rnf tcm `seq` rnf tcn
#endif

----------------------------------------------------------------------------
-- GHC Specifics

#if __GLASGOW_HASKELL__ >= 702
-- |/Since: 1.4.0.0/
instance NFData Fingerprint where
    rnf (Fingerprint _ _) = ()
#endif

----------------------------------------------------------------------------
-- Foreign.C.Types

-- |/Since: 1.4.0.0/
instance NFData CChar where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CSChar where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CUChar where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CShort where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CUShort where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CInt where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CUInt where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CLong where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CULong where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CPtrdiff where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CSize where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CWchar where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CSigAtomic where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CLLong where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CULLong where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CIntPtr where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CUIntPtr where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CIntMax where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CUIntMax where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CClock where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CTime where rnf !_ = ()

#if MIN_VERSION_base(4,4,0)
-- |/Since: 1.4.0.0/
instance NFData CUSeconds where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CSUSeconds where rnf !_ = ()
#endif

-- |/Since: 1.4.0.0/
instance NFData CFloat where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CDouble where rnf !_ = ()

-- NOTE: The types `CFile`, `CFPos`, and `CJmpBuf` below are not
-- newtype wrappers rather defined as field-less single-constructor
-- types.

-- |/Since: 1.4.0.0/
instance NFData CFile where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CFpos where rnf !_ = ()

-- |/Since: 1.4.0.0/
instance NFData CJmpBuf where rnf !_ = ()

----------------------------------------------------------------------------
-- Tuples

instance (NFData a, NFData b) => NFData (a,b) where
  rnf (x,y) = rnf x `seq` rnf y

instance (NFData a, NFData b, NFData c) => NFData (a,b,c) where
  rnf (x,y,z) = rnf x `seq` rnf y `seq` rnf z

instance (NFData a, NFData b, NFData c, NFData d) => NFData (a,b,c,d) where
  rnf (x1,x2,x3,x4) = rnf x1 `seq`
                      rnf x2 `seq`
                      rnf x3 `seq`
                      rnf x4

instance (NFData a1, NFData a2, NFData a3, NFData a4, NFData a5) =>
         NFData (a1, a2, a3, a4, a5) where
  rnf (x1, x2, x3, x4, x5) =
                  rnf x1 `seq`
                  rnf x2 `seq`
                  rnf x3 `seq`
                  rnf x4 `seq`
                  rnf x5

instance (NFData a1, NFData a2, NFData a3, NFData a4, NFData a5, NFData a6) =>
         NFData (a1, a2, a3, a4, a5, a6) where
  rnf (x1, x2, x3, x4, x5, x6) =
                  rnf x1 `seq`
                  rnf x2 `seq`
                  rnf x3 `seq`
                  rnf x4 `seq`
                  rnf x5 `seq`
                  rnf x6

instance (NFData a1, NFData a2, NFData a3, NFData a4, NFData a5, NFData a6, NFData a7) =>
         NFData (a1, a2, a3, a4, a5, a6, a7) where
  rnf (x1, x2, x3, x4, x5, x6, x7) =
                  rnf x1 `seq`
                  rnf x2 `seq`
                  rnf x3 `seq`
                  rnf x4 `seq`
                  rnf x5 `seq`
                  rnf x6 `seq`
                  rnf x7

instance (NFData a1, NFData a2, NFData a3, NFData a4, NFData a5, NFData a6, NFData a7, NFData a8) =>
         NFData (a1, a2, a3, a4, a5, a6, a7, a8) where
  rnf (x1, x2, x3, x4, x5, x6, x7, x8) =
                  rnf x1 `seq`
                  rnf x2 `seq`
                  rnf x3 `seq`
                  rnf x4 `seq`
                  rnf x5 `seq`
                  rnf x6 `seq`
                  rnf x7 `seq`
                  rnf x8

instance (NFData a1, NFData a2, NFData a3, NFData a4, NFData a5, NFData a6, NFData a7, NFData a8, NFData a9) =>
         NFData (a1, a2, a3, a4, a5, a6, a7, a8, a9) where
  rnf (x1, x2, x3, x4, x5, x6, x7, x8, x9) =
                  rnf x1 `seq`
                  rnf x2 `seq`
                  rnf x3 `seq`
                  rnf x4 `seq`
                  rnf x5 `seq`
                  rnf x6 `seq`
                  rnf x7 `seq`
                  rnf x8 `seq`
                  rnf x9
