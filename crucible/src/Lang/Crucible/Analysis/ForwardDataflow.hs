{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
------------------------------------------------------------------------
-- |
-- Module      : Lang.Crucible.Analysis.ForwardDataflow
-- Description : Forward dataflow analysis framework based on Kildall's algorithm
-- Copyright   : (c) Galois, Inc 2015
-- Maintainer  : Rob Dockins <rdockins@galois.com>
-- Stability   : provisional
-- License     : BSD3
--
-- This module defines a generic framework for forward dataflow analysis,
-- with some additional control-flow data on the side.
--
-- We calculate a fixpoint of a given analysis via the straightforward
-- method of iterating the transfer function until no more updates occur.
--
-- Our current method for doing this is quite naive, and more effiecent
-- methods exist.
------------------------------------------------------------------------
module Lang.Crucible.Analysis.ForwardDataflow where

import Prelude hiding (foldr)
import Data.Set (Set)
import qualified Data.Set as Set

import Control.Monad.State.Strict

import Data.Parameterized.Context ( Assignment )
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.TraversableFC

import Lang.Crucible.Types
import Lang.Crucible.Core

import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Debug.Trace as Debug

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif

-----------------------
data SymDom = Dead | Symbolic | Concrete
  deriving (Eq, Ord, Show)

symbolicResults
   :: CFG blocks init ret
   -- -> Assignment (Ignore SymDom) init
   -> String
   -- -> (Assignment (KildallPair (Assignment (Ignore SymDom)) SymDom) blocks, Ignore SymDom ret, SymDom)
symbolicResults cfg = show $ kildall_forward symbolicAnalysis cfg (begin, Concrete)
 where sz = Ctx.size (blockInputs (getBlock (cfgEntryBlockID cfg) (cfgBlockMap cfg)))
       begin = Ctx.generate sz (\_ -> Ignore Symbolic)


symlub :: SymDom -> SymDom -> SymDom
symlub Dead x = x
symlub x Dead = x
symlub Symbolic _ = Symbolic
symlub _ Symbolic = Symbolic
symlub Concrete Concrete = Concrete

sym_reg_transfer :: Reg ctx tp -> Assignment (Ignore SymDom) ctx -> SymDom
sym_reg_transfer reg asgn = ignoreOut $ asgn Ctx.! (regIndex reg)

sym_expr_transfer :: Expr ctx tp -> Assignment (Ignore SymDom) ctx -> SymDom
sym_expr_transfer (App a) asgn
  = foldApp (\r z -> symlub z $ sym_reg_transfer r asgn) Dead a

-- FIXME this whole shabang is bogus, and should be replace by something that works...
-- we assume every function other than "matlabFunctionHandle" returns a symbolic
-- output, but does not have control flow that depends on symbolic data...
sym_call_transfer
  :: CtxRepr args
  -> TypeRepr ret
  -> Reg ctx (FunctionHandleType args ret)
  -> Ignore SymDom (FunctionHandleType args ret)
  -> Assignment a args
  -> Ignore SymDom ret
sym_call_transfer _ _ ex _ _
  = Debug.trace (show $ pretty ex) $ Ignore Symbolic

symbolicAnalysis :: KildallForward blocks (Ignore SymDom) SymDom
symbolicAnalysis =
  KildallForward
  { kfwd_lub = \(Ignore x) (Ignore y) -> Ignore (symlub x y)
  , kfwd_bot = Ignore Dead
  , kfwd_club = symlub
  , kfwd_cbot = Dead
  , kfwd_same = \(Ignore x) (Ignore y) -> x == y
  , kfwd_csame = \x y -> x == y
  , kfwd_br = \_ (Ignore x) y -> let z = symlub x y in (z, z)
  , kfwd_maybe = \_ _ (Ignore x) y -> let z = symlub x y in (z, Ignore x, z)
  , kfwd_mswitch = \_ (Ignore x) y ->
          let z = symlub x y
           in constMSwitch (KP (Ignore x) z)
  , kfwd_reg  = \_ ex asgn -> Ignore $ sym_reg_transfer ex asgn
  , kfwd_expr = \_ ex asgn -> Ignore $ sym_expr_transfer ex asgn
  , kfwd_call = sym_call_transfer
  , kfwd_rdglobal = \_ -> Ignore Symbolic
             -- FIXME, here we make the totally pessimistic assumption
             -- that every global variable read is symbolic
  , kfwd_onentry = \_ x -> x
  }

-------------------

data KildallPair (a::k -> *) (c :: *) (tp::k) = KP (a tp) c
newtype Ignore a (b::k) = Ignore { ignoreOut :: a }
 deriving (Eq, Ord, Show)

instance (ShowF a, Show c) => ShowF (KildallPair a c) where
  showF (KP x y) = "(" ++ showF x ++ ", " ++ show y ++ ")"
instance (ShowF a, Show c) => Show (KildallPair a c tp) where
  show = showF

instance Show a => ShowF (Ignore a) where
  showF (Ignore x) = show x



data KildallForward blocks (a :: CrucibleType -> *) c
  = KildallForward
    { kfwd_lub      :: forall tp. a tp -> a tp -> a tp
    , kfwd_bot      :: forall tp. a tp
    , kfwd_club     :: c -> c -> c
    , kfwd_cbot     :: c
    , kfwd_same     :: forall tp. a tp -> a tp -> Bool
    , kfwd_csame    :: c -> c -> Bool
    , kfwd_br       :: forall ctx. Reg ctx BoolType -> a BoolType -> c -> (c, c)
    , kfwd_maybe    :: forall ctx tp. TypeRepr tp -> Reg ctx (MaybeType tp) -> a (MaybeType tp) -> c -> (c, a tp, c)
    , kfwd_mswitch  :: forall ctx. Reg ctx MatlabValueType -> a MatlabValueType -> c -> MSwitch (KildallPair a c)
    , kfwd_reg      :: !(forall ctx tp. TypeRepr tp -> Reg ctx tp  -> Assignment a ctx -> a tp)
    , kfwd_expr     :: !(forall ctx tp. TypeRepr tp -> Expr ctx tp -> Assignment a ctx -> a tp)
    , kfwd_call     :: forall ctx args ret. CtxRepr args
                                         -> TypeRepr ret
                                         -> Reg ctx (FunctionHandleType args ret)
                                         -> a (FunctionHandleType args ret)
                                         -> Assignment a args
                                         -> a ret
    , kfwd_rdglobal :: forall tp. GlobalVar tp -> a tp
    , kfwd_onentry  :: forall ctx. BlockID blocks ctx -> (Assignment a ctx, c) -> (Assignment a ctx, c)
    }

kildall_transfer
   :: forall a c blocks ret ctx
    . KildallForward blocks a c
   -> TypeRepr ret
   -> Block blocks ret ctx
   -> (Assignment a ctx, c)
   -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))
kildall_transfer analysis retRepr blk = transfer_seq (_blockStmts blk)
 where transfer_seq :: forall ctx'
                     . StmtSeq blocks ret ctx'
                    -> (Assignment a ctx', c)
                    -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))

       transfer_seq (ConsStmt _loc stmt ss) x = transfer_seq ss (transfer_stmt stmt x)
       transfer_seq (TermStmt _loc term) x = transfer_term term x

       transfer_stmt :: forall ctx1 ctx2. Stmt ctx1 ctx2 -> (Assignment a ctx1, c) -> (Assignment a ctx2, c)
       transfer_stmt (SetReg tp ex) (asgn, c) = (Ctx.extend asgn (kfwd_expr analysis tp ex asgn), c)
       transfer_stmt (CallHandle rettp ex argstp actuals) (asgn, c) =
           let xs = Ctx.zipWith (\tp act -> kfwd_reg analysis tp act asgn) argstp actuals
               ex_sh = kfwd_reg analysis (FunctionHandleRepr argstp rettp) ex asgn
               a' = kfwd_call analysis argstp rettp ex ex_sh xs
            in (Ctx.extend asgn a', c)
       transfer_stmt (Print _) asgn = asgn
       transfer_stmt (ReadGlobal gv) (asgn, c) = (Ctx.extend asgn (kfwd_rdglobal analysis gv), c)
       transfer_stmt NewRefCell{} _ = error "forward dataflow: reference cell!"
       transfer_stmt ReadRefCell{} _ = error "forward dataflow: reference cell!"
       transfer_stmt WriteRefCell{} _ = error "forward dataflow: reference cell!"
       transfer_stmt (WriteGlobal _ _) asgnc = asgnc -- FIXME? need to check something here, perhaps?
       transfer_stmt (Assert _ _) asgnc = asgnc -- FIXME? is it useful to remember assertions some way?

       transfer_term :: forall ctx'
                      . TermStmt blocks ret ctx'
                     -> (Assignment a ctx', c)
                     -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))

       transfer_term (ErrorStmt _) _ = return Set.empty

       transfer_term (Jump tgt) x = transfer_jump tgt x

       transfer_term (Br ex tgt1 tgt2) (asgn,c) = do
           let a = kfwd_reg analysis knownRepr ex asgn
           let (c1,c2) = kfwd_br analysis ex a c
           s1 <- transfer_jump tgt1 (asgn,c1)
           s2 <- transfer_jump tgt2 (asgn,c2)
           return (Set.union s1 s2)

       transfer_term (Return ex) (asgn, c) = do
           let a = kfwd_reg analysis retRepr ex asgn
           modify (\ (x,r,rc) -> (x, kfwd_lub analysis r a, kfwd_club analysis rc c))
           return Set.empty

       transfer_term (TailCall fn callargs actuals) (asgn, c) = do
           let xs = Ctx.zipWith (\tp act -> kfwd_reg analysis tp act asgn) callargs actuals
           let fn_sh = kfwd_reg analysis (FunctionHandleRepr callargs retRepr) fn asgn
           let a' = kfwd_call analysis callargs retRepr fn fn_sh xs
           modify (\ (x,r,rc) -> (x, kfwd_lub analysis r a', kfwd_club analysis rc c))
           return Set.empty

       transfer_term (MaybeBranch tp ex swtgt jmptgt) (asgn, c) = do
           let a = kfwd_reg analysis (MaybeRepr tp) ex asgn
           let (c1, a1, c2) = kfwd_maybe analysis tp ex a c
           s1 <- transfer_switch swtgt a1 (asgn, c1)
           s2 <- transfer_jump jmptgt (asgn, c2)
           return (Set.union s1 s2)

       transfer_term (VariantElim _ctx _ex _switch) (_asgn, _c) = do
           fail "FIXME: transfer_term for VariantElim not implemented"

       transfer_term (MSwitchStmt ex switch) (asgn, c) = do
           let a = kfwd_reg analysis knownRepr ex asgn
           let ms = kfwd_mswitch analysis ex a c
           Set.unions <$> sequence
              [ transfer_switch_branch asgn (matchRealArray ms)   (matchRealArray switch)
              , transfer_switch_branch asgn (matchIntArray ms)    (matchIntArray switch)
              , transfer_switch_branch asgn (matchUIntArray ms)   (matchUIntArray switch)
              , transfer_switch_branch asgn (matchLogicArray ms)  (matchLogicArray switch)
              , transfer_switch_branch asgn (matchCharArray ms)   (matchCharArray switch)
              , transfer_switch_branch asgn (matchCellArray ms)   (matchCellArray switch)
              , transfer_switch_branch asgn (matchStructArray ms) (matchStructArray switch)
              , transfer_switch_branch asgn (matchHandle ms)      (matchHandle switch)
              , transfer_switch_branch asgn (matchSymLogicArray ms) (matchSymLogicArray switch)
              , transfer_switch_branch asgn (matchSymRealArray ms)  (matchSymRealArray switch)
              , transfer_switch_branch asgn (matchSymCplxArray ms)  (matchSymCplxArray switch)
              ]

       transfer_switch_branch
                        :: forall ctx' tp
                         . Assignment a ctx'
                        -> KildallPair a c tp
                        -> SwitchTarget blocks ctx' tp
                        -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))
       transfer_switch_branch asgn (KP a c) tgt = transfer_switch tgt a (asgn, c)

       transfer_switch :: forall ctx' tp
                        . SwitchTarget blocks ctx' tp
                       -> a tp
                       -> (Assignment a ctx', c)
                       -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))
       transfer_switch (SwitchTarget tgt argstp actuals) a1 (asgn, c) = do
           let xs = Ctx.zipWith (\tp act -> kfwd_reg analysis tp act asgn) argstp actuals
           let xs' = Ctx.extend xs a1
           transfer_target tgt (xs', c)

       transfer_jump :: forall ctx'
                      . JumpTarget blocks ctx'
                     -> (Assignment a ctx', c)
                     -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))

       transfer_jump (JumpTarget tgt argstp actuals) (asgn, c) = do
           let xs = Ctx.zipWith (\tp act -> kfwd_reg analysis tp act asgn) argstp actuals
           transfer_target tgt (xs, c)

       transfer_target :: forall ctx'
                        . BlockID blocks ctx'
                       -> (Assignment a ctx', c)
                       -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) (Set (Some (BlockID blocks)))
       transfer_target tgt@(BlockID idx) (asgn, c) = do
           (x,r,rc) <- get
           let KP old oldc = x Ctx.! idx
           let new = Ctx.zipWith (\a b -> kfwd_lub analysis a b) old asgn
           let zipsame = Ctx.zipWith (\a b -> Ignore $ kfwd_same analysis a b) old new
           let samex = foldlFC (\a (Ignore b) -> a && b) True zipsame
           let newc = kfwd_club analysis c oldc
           let same = samex && kfwd_csame analysis oldc newc
           if same
               then return Set.empty
               else do put (Ctx.update idx (KP new newc) x, r, rc)
                       return (Set.singleton (Some tgt))



kildall_forward
  :: forall a c blocks ret init
   . KildallForward blocks a c
  -> CFG blocks init ret
  -> (Assignment a init, c)
  -> (Assignment (KildallPair (Assignment a) c) blocks, a ret, c)
kildall_forward analysis cfg (asgn0,c0) =
    let initblk@(BlockID idx) = cfgEntryBlockID cfg

        freshAsgn :: Ctx.Index blocks ctx -> Assignment a ctx
        freshAsgn i = fmapFC (\_ -> kfwd_bot analysis)
                             (blockInputs (getBlock (BlockID i) (cfgBlockMap cfg)))

     in execState (loop (Set.singleton (Some initblk)))
                  ( Ctx.update idx (KP asgn0 c0) $
                       Ctx.generate (Ctx.size (cfgBlockMap cfg)) (\i -> KP (freshAsgn i) (kfwd_cbot analysis))
                  , kfwd_bot analysis
                  , kfwd_cbot analysis
                  )

  where visit :: Block blocks ret ctx
              -> (Assignment a ctx, c)
              -> Set (Some (BlockID blocks))
              -> State (Assignment (KildallPair (Assignment a) c) blocks, a ret, c) ()
        visit blk start worklist = do
            s <- kildall_transfer analysis (cfgReturnType cfg) blk start
            loop (Set.union s worklist)

        loop worklist =
           case Set.minView worklist of
              Nothing -> return ()
              Just (Some tgt@(BlockID idx), worklist') ->
                  do (x,_,_) <- get
                     let (KP a c) = x Ctx.! idx
                         (a',c') = kfwd_onentry analysis tgt (a,c)
                     visit (getBlock tgt (cfgBlockMap cfg)) (a',c') worklist'
