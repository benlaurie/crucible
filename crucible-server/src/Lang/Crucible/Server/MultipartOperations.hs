-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Server.MultipartOperations
-- Copyright        : (c) Galois, Inc 2014-2016
-- Maintainer       : Rob Dockins <rdockins@galois.com>
-- Stability        : provisional
-- License          : BSD3
--
-- Support operations for performing loads and stores into byte-oriented
-- memory strucutures.
------------------------------------------------------------------------

{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Lang.Crucible.Server.MultipartOperations where

#if !MIN_VERSION_base(4,8,0)
import           Control.Applicative
#endif
import           Control.Lens
import           Control.Monad.ST (RealWorld, stToIO)
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Text as Text

import           Lang.Crucible.Analysis.Postdom
import qualified Lang.Crucible.Core as C
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.FunctionName
import qualified Lang.Crucible.Generator as Gen
import           Lang.Crucible.ProgramLoc
import qualified Lang.Crucible.RegCFG as R
import           Lang.Crucible.SSAConversion (toSSA)
import           Lang.Crucible.Server.Simulator
import           Lang.Crucible.Simulator.MSSim
import           Lang.Crucible.Syntax
import           Lang.Crucible.Types


-- | This function constructs a crucible function for storing multibyte
--   values into a word map.  It supports both big- and
--   little-endian encoding.  The first argument to the constructed function
--   is a boolean: true is for big-endian; false for little-endian.
--   The next argument is the base address, followed by a value to write,
--   followed by the word map to write into.  The bitwidth of the value to write
--   must be equal to the cellsize times the number of cells to write.
--   The function will return a modified word map with the data written according
--   to the selected endian encoding.  Despite calling this a multibyte operation,
--   bytes (i.e., 8-bit cells) are not assumed; the cell width may be any positive size.
multipartStoreFn :: forall sym addrWidth cellWidth valWidth
                   . (1 <= addrWidth, 1 <= cellWidth, 1 <= valWidth)
                  => Simulator sym
                  -> NatRepr addrWidth
                  -> NatRepr cellWidth
                  -> NatRepr valWidth
                  -> Int -- ^ number of bytes to write
                  -> IO (FnHandle (EmptyCtx
                               ::> BoolType
                               ::> BVType addrWidth
                               ::> BVType valWidth
                               ::> WordMapType addrWidth (BaseBVType cellWidth)
                               )
                               (WordMapType addrWidth (BaseBVType cellWidth)))
multipartStoreFn sim addrWidth cellWidth valWidth num = do
    let nameStr = ("multipartStore_"++(show addrWidth)++"_"++(show cellWidth)++"_"++(show num))
    let name = functionNameFromText $ Text.pack nameStr
    let argsRepr = Ctx.empty
                   Ctx.%> BoolRepr
                   Ctx.%> BVRepr addrWidth
                   Ctx.%> BVRepr valWidth
                   Ctx.%> WordMapRepr addrWidth (BaseBVRepr cellWidth)
    let retRepr = WordMapRepr addrWidth (BaseBVRepr cellWidth)
    h <- simMkHandle sim name argsRepr retRepr
    (R.SomeCFG regCfg, _) <- stToIO $ Gen.defineFunction InternalPos h fndef
    case toSSA regCfg of
      C.SomeCFG cfg -> do
        bindHandleToFunction sim h (UseCFG cfg (postdomInfo cfg))
        return h

 where fndef :: Gen.FunctionDef RealWorld
                                Maybe
                                (EmptyCtx
                                 ::> BoolType
                                 ::> BVType addrWidth
                                 ::> BVType valWidth
                                 ::> WordMapType addrWidth (BaseBVType cellWidth)
                                )
                               (WordMapType addrWidth (BaseBVType cellWidth))

       fndef regs = ( Nothing, Gen.endNow $ \_ -> do
                          let endianFlag = regs^._1
                          let basePtr    = R.AtomExpr (regs^._2)
                          let v          = R.AtomExpr (regs^._3)
                          let wordMap    = R.AtomExpr (regs^._4)

                          be <- Gen.newLabel
                          le <- Gen.newLabel

                          Gen.endCurrentBlock (R.Br endianFlag be le)
                          Gen.defineBlock be $ Gen.returnFromFunction $
                                bigEndianStore addrWidth cellWidth valWidth num basePtr v wordMap
                          Gen.defineBlock le $ Gen.returnFromFunction $
                                littleEndianStore addrWidth cellWidth valWidth num basePtr v wordMap
                    )


-- | This function constructs a crucible function for loading multibyte
--   values from a word map.  It supports both big- and
--   little-endian encoding.  The first argument to the constructed function
--   is a boolean: true is for big-endian; false for little-endian.
--   The next argument is the base address, followed by the word map to read from.
--   The result of this function is a value decoded from the based address
--   using the selected endianess; its bitwidth will be the cell size times the number
--   of cells to read.  The fourth argument to this function is an optional default value.
--   When the default is a Hothing value and any address required by this load is not defined,
--   an error will result.  However, if a `Just` value is given as the default, that
--   default value will be the result of reading from the word map at any undefined location.
--
--   Note: bytes (i.e., 8-bit cells) are not assumed; the cell width may be any positive size.
multipartLoadFn :: forall sym addrWidth cellWidth valWidth
                   . (1 <= addrWidth, 1 <= cellWidth, 1 <= valWidth)
                  => Simulator sym
                  -> NatRepr addrWidth
                  -> NatRepr cellWidth
                  -> NatRepr valWidth
                  -> Int -- ^ numer of cells to read
                  -> IO (FnHandle (EmptyCtx
                               ::> BoolType
                               ::> BVType addrWidth
                               ::> WordMapType addrWidth (BaseBVType cellWidth)
                               ::> MaybeType (BVType cellWidth)
                               )
                               (BVType valWidth))
multipartLoadFn sim addrWidth cellWidth valWidth num = do
    let nameStr = ("multipartLoad_"++(show addrWidth)++"_"++(show cellWidth)++"_"++(show num))
    let name = functionNameFromText $ Text.pack nameStr
    let argsRepr = Ctx.empty
                   Ctx.%> BoolRepr
                   Ctx.%> BVRepr addrWidth
                   Ctx.%> WordMapRepr addrWidth (BaseBVRepr cellWidth)
                   Ctx.%> MaybeRepr (BVRepr cellWidth)
    let retRepr = BVRepr valWidth
    h <- simMkHandle sim name argsRepr retRepr
    (R.SomeCFG regCfg, _) <- stToIO $ Gen.defineFunction InternalPos h fndef
    case toSSA regCfg of
      C.SomeCFG cfg -> do
        bindHandleToFunction sim h (UseCFG cfg (postdomInfo cfg))
        return h

 where fndef :: Gen.FunctionDef RealWorld
                               Maybe
                               (EmptyCtx
                               ::> BoolType
                               ::> BVType addrWidth
                               ::> WordMapType addrWidth (BaseBVType cellWidth)
                               ::> MaybeType (BVType cellWidth)
                               )
                               (BVType valWidth)

       fndef args = ( Nothing, Gen.endNow $ \_ -> do
                          let endianFlag = args^._1
                          let basePtr    = R.AtomExpr (args^._2)
                          let wordMap    = R.AtomExpr (args^._3)
                          let maybeDefVal = args^._4

                          be       <- Gen.newLabel
                          le       <- Gen.newLabel
                          be_nodef <- Gen.newLabel
                          le_nodef <- Gen.newLabel
                          be_def   <- Gen.newLambdaLabel' (BVRepr cellWidth)
                          le_def   <- Gen.newLambdaLabel' (BVRepr cellWidth)

                          Gen.endCurrentBlock (R.Br endianFlag be le)

                          Gen.defineBlock be $ Gen.endNow $ \_ -> Gen.endCurrentBlock $
                                R.MaybeBranch (BVRepr cellWidth) maybeDefVal be_def be_nodef

                          Gen.defineBlock le $ Gen.endNow $ \_ -> Gen.endCurrentBlock $
                                R.MaybeBranch (BVRepr cellWidth) maybeDefVal le_def le_nodef

                          Gen.defineBlock be_nodef $ Gen.returnFromFunction $
                               bigEndianLoad addrWidth cellWidth valWidth num basePtr wordMap

                          Gen.defineBlock le_nodef $ Gen.returnFromFunction $
                               littleEndianLoad addrWidth cellWidth valWidth num basePtr wordMap

                          Gen.defineLambdaBlock be_def $ \def -> Gen.returnFromFunction $
                               bigEndianLoadDef addrWidth cellWidth valWidth num basePtr wordMap def

                          Gen.defineLambdaBlock le_def $ \def -> Gen.returnFromFunction $
                               littleEndianLoadDef addrWidth cellWidth valWidth num basePtr wordMap def
                    )
