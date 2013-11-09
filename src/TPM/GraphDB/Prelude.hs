module TPM.GraphDB.Prelude 
  ( 
    -- base
    module Prelude,
    module Control.Monad,
    module Control.Applicative,
    module Control.Arrow,
    module Control.Category,
    module Data.Monoid,
    module Data.Foldable,
    module Data.Traversable,
    module Data.Maybe,
    module Data.List,
    module Data.Tuple,
    module Data.Ord,
    module Data.String,
    module Data.Int,
    module Data.Word,
    module Data.Data,
    module Text.Read,
    module Control.Exception,
    module Control.Concurrent,
    module System.Exit,
    module System.IO.Unsafe,
    module Unsafe.Coerce,
    module GHC.Exts,
    module GHC.Generics,
    module Debug.Trace,
    module Data.IORef,
    module Data.STRef,
    module Control.Monad.ST,

    -- mtl
    module Control.Monad.State,
    module Control.Monad.Reader,
    module Control.Monad.Writer,

    -- transformers
    module Control.Monad.IO.Class,
    module Control.Monad.Trans.Maybe,

    -- stm
    module Control.Concurrent.STM,
    
    -- containers
    module Data.Map,
    module Data.IntMap,
    module Data.Set,
    module Data.IntSet,

    -- text
    module Data.Text,

    -- bytestring
    module Data.ByteString,

    -- system-filepath
    module Filesystem.Path,

    -- hashable
    module Data.Hashable,

    -- safecopy
    module Data.SafeCopy,
    
    -- either
    module Control.Error,

    -- monad-stm
    module Control.Monad.STM.Class,


    LazyByteString,
    LazyText,

    (?:),
    traceM,
  )
  where

-- base
import Prelude hiding (concat, foldr, mapM_, sequence_, foldl1, maximum, minimum, product, sum, all, and, any, concatMap, elem, foldl, foldr1, notElem, or, mapM, sequence, FilePath, id, (.))
import Control.Monad hiding (mapM_, sequence_, forM_, msum, mapM, sequence, forM)
import Control.Applicative
import Control.Arrow hiding (left, right)
import Control.Category
import Data.Monoid
import Data.Foldable
import Data.Traversable
import Data.Maybe
import Data.List hiding (concat, foldr, foldl1, maximum, minimum, product, sum, all, and, any, concatMap, elem, foldl, foldr1, notElem, or, find, maximumBy, minimumBy, mapAccumL, mapAccumR, foldl')
import Data.Tuple
import Data.Ord (Down(..))
import Data.String
import Data.Int
import Data.Word
import Data.Data
import Text.Read (readMaybe, readEither)
import Control.Exception hiding (tryJust)
import Control.Concurrent
import System.Exit
import System.IO.Unsafe
import Unsafe.Coerce
import GHC.Exts (groupWith, sortWith)
import GHC.Generics (Generic)
import Debug.Trace
import Data.IORef
import Data.STRef
import Control.Monad.ST

-- mtl
import Control.Monad.State hiding (mapM_, sequence_, forM_, msum, mapM, sequence, forM)
import Control.Monad.Reader hiding (mapM_, sequence_, forM_, msum, mapM, sequence, forM)
import Control.Monad.Writer hiding (mapM_, sequence_, forM_, msum, mapM, sequence, forM)

-- transformers
import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe

-- stm
import Control.Concurrent.STM

-- containers
import Data.Map (Map)
import Data.IntMap (IntMap)
import Data.Set (Set)
import Data.IntSet (IntSet)

-- text
import Data.Text (Text)

-- bytestring
import Data.ByteString (ByteString)

-- system-filepath
import Filesystem.Path (FilePath)

-- hashable
import Data.Hashable (Hashable(..), hash)

-- safecopy
import Data.SafeCopy (SafeCopy)

-- either
import Control.Error

-- monad-stm
import Control.Monad.STM.Class

import qualified Data.ByteString.Lazy
import qualified Data.Text.Lazy


type LazyByteString = Data.ByteString.Lazy.ByteString
type LazyText = Data.Text.Lazy.Text


(?:) :: Maybe a -> a -> a
maybeA ?: b = fromMaybe b maybeA
{-# INLINE (?:) #-}

traceM :: (Monad m) => String -> m ()
traceM s = trace s $ return ()
