{-# LANGUAGE GADTs,KindSignatures #-}
module Judgement where

import Data.Monoid

import Utils
import TypeSyn
import DualSyn
import VariableSyn

data TypeScheme :: * where
  TyMono   :: Type -> TypeScheme
  TyForall :: Variable -> TypeScheme -> TypeScheme
  deriving Eq

instance Pretty TypeScheme where
  pp (TyMono ty)     = pp ty
  pp (TyForall v ty) = "∀" <+> pp v <> "." <+> pp ty

--------------------------------------------------------------------------------
--                              Top Level                                     --
--------------------------------------------------------------------------------

typeOfProgram :: Program Term -> Std Type
typeOfProgram (Pgm decls term) = infer (mkContext decls) term

--------------------------------------------------------------------------------
--                                isType                                      --
--------------------------------------------------------------------------------
{- Checks whether a type is well formed -}

isType :: [Decl]              -- ^ A set of type signatures
       -> [(Variable,Type)] -- ^ A context of bindings of type variables
       -> Type
       -> Bool
isType _ _   TyInt         = True
isType s ctx (TyArr a b)   = isType s ctx a && isType s ctx b
isType s ctx (TyVar v)     = case lookup v ctx of
                               Just t -> isType s ctx t
                               Nothing -> False

{- A standalone type constructor is only valid if its arity is 0 -}
isType s _   (TyCons tc)   = case lookupDecl tc s of
                               Just d -> declArity d == 0
                               Nothing -> False
isType s ctx ty@(TyApp _ _) = case collectTyArgs ty of
                               Just (tc,tys) ->
                                 case lookupDecl tc s of
                                   Just d -> (all (isType s ctx) tys)
                                          && (length tys == declArity d)
                                   Nothing -> False
                               Nothing -> False

--------------------------------------------------------------------------------
--                              Infer TypeScheme                              --
--------------------------------------------------------------------------------
{- Type scheme inference with algorithm W. -}

-- inferTSProgram :: Program Term -> TypeScheme
-- inferTSProgram pgm = inferTS (mkContext . pgmDecls $ pgm)
--                              (pgmTerm pgm)

-- inferTS :: [(Variable,Type)] -> Term -> TypeScheme
-- inferTS _ (Lit _)    = TyMono TyInt
-- inferTS c (Add a b)  = case (inferTS c a,inferTS c b) of
--                          (TyMono TyInt, TyMono TyInt) -> TyMono TyInt
--                          _ -> error "(+) requires it's arguments to be of type Int"
-- inferTS c (Var v)    = case lookup v c of
--                          Just t -> TyMono t
--                          Nothing -> error ("unbound variable " <> v)
-- inferTS c (Fix _ t)  = inferTS c t
-- inferTS c (App a b)  = case inferTS c a of
--                          (TyMono (TyArr aTy0 aTy1)) ->
--                            case inferTS c b of
--                              TyMono bTy ->
--                                case bTy == aTy0 of
--                                  True -> TyMono aTy1
--                                  False -> error ("expecting type" <+> pp aTy1)
--                              t -> error ("must be a function type, given" <+> pp t)
--                          t -> error ("must be a function type, given" <+> pp t)
-- inferTS c (Cons k)   = case lookup k c of
--                          Just t -> TyMono t
--                          Nothing -> error ("unbound constructor " <> k)
-- inferTS c (Case e a) = let _ = inferTS c e
--                            tyAlts = map inferTSAlt a
--                        in case tyAlts of
--                             [] -> error "cannot infer empty case"
--                             (t:ts) -> case all (== t) ts of
--                                         True -> t
--                                         False -> error "all case branches must have the same type"
--   where inferTSAlt :: (Pattern,Term) -> TypeScheme
--         inferTSAlt (_,t) = inferTS c t

--         -- inferTSPattern :: Pattern -> TypeScheme
--         -- inferTSPattern PWild        = TyForall "x" (TyVar "x")
--         -- inferTSPattern (PVar _)     = TyForall "x" (TyVar "x")
--         -- inferTSPattern (PCons _ _)  = undefined

-- inferTS c (Dest h)   = case lookup h c of
--                          Just t -> TyMono t
--                          Nothing -> error ("unbound destructor " <> h)
-- inferTS c (CoCase a) = undefined c a

-- typeClosure :: Type -> TypeScheme
-- typeClosure ty =
--   case freeTyVars ty of
--     [] -> TyMono ty
--     vs -> foldr (\v' a -> TyForall v' ) v vs

{- Since there is no forall type, all type variables occur free. -}
freeTyVars :: Type -> [Variable]
freeTyVars TyInt = []
freeTyVars (TyArr a b) = freeTyVars a <> freeTyVars b
freeTyVars (TyVar v) = [v]
freeTyVars (TyCons _) = []
freeTyVars (TyApp a b) = freeTyVars a <> freeTyVars b


occurs :: Variable -> Type -> Bool
occurs _ TyInt       = False
occurs v (TyArr a b) = occurs v a || occurs v b
occurs v (TyVar v')  = v == v'
occurs v (TyCons k)  = v == k
occurs v (TyApp a b) = occurs v a || occurs v b

unify :: Type -> Type -> Std Type
unify a@(TyVar a') b@(TyVar b') =
  case a' == b' of
    True -> return a
    False -> typeErr ("cannot unify" <+> pp a <+> "and" <+> pp b)
unify (TyVar a') b =
  case occurs a' b of
    True -> typeErr ("cannot unify recursion in type" <+> pp b)
    False -> return b
unify b (TyVar a') =
  case occurs a' b of
    True -> typeErr ("cannot unify recursion in type" <+> pp b)
    False -> return b
unify (TyCons a) (TyCons b) =
  case a == b of
    True -> return (TyCons a)
    False -> typeErr ("cannot unify" <+> pp a <+> " and " <+> pp b)
unify (TyApp a b) (TyApp a' b') = TyApp <$> unify a a' <*> unify b b'
unify (TyArr a b) (TyArr a' b') = TyArr <$> unify a a' <*> unify b b'
unify a b = typeErr ("cannot unify" <+> pp a <+> "and" <+> pp b)

--------------------------------------------------------------------------------
--                              Bidirectional Tc                              --
--------------------------------------------------------------------------------
{- Attempt at a bidirectional typechecker. We do not include declarations in the
~infer~ and ~check~ functions because we populate the Ctx with the necessary
information before running.
-}

-----------
-- infer --
-----------
infer :: Ctx -> Term -> Std Type
infer c (Let x a b) =
  do { aty <- infer c a
     ; infer ((x,aty):c) b }

infer c (Ann a ty) = check c a ty >> return ty

infer _ (Lit _) = return TyInt

infer c (Add a b) =
  do { check c a TyInt
     ; check c b TyInt
     ; return TyInt }

infer c (Var v) = lookupStd v c
infer c (Fix _ t) = infer c t
infer c (Cons k) = lookupStd k c
infer c (Dest h) = lookupStd h c

infer c (App a b) =
  do { ty <- infer c a
     ; case ty of
         TyArr tyDom tyCod ->
           do { check c b tyDom
              ; return tyCod }
         _ -> typeErr ("must have a function type: " ++ pp a)
     }

infer c (Case e alts) =
  do { ety <- infer c e
     ; tys <- mapM (\(p,u) -> checkPat c p ety >>= \c' -> infer c' u)
                   alts
     ; case tys of
         [] -> typeErr "cannot type empty case"
         (t:ts) ->
           case all (== t) ts of
             True  -> return t
             False -> typeErr "all branches must return the same type."
     }

infer _ (CoCase _) = unimplementedErr "infer{CoCase}"
{- Consider the term
```
  fst { fst □ -> 42 }
```
We must check that the arugment
-}

infer c (Prompt t) = infer c t

inferCopat :: Ctx -> Type -> CoPattern -> Std (Type,Ctx)
inferCopat c ety QHead = return (ety,c)
inferCopat c ety (QDest h q) =
  do { (qty,c') <- inferCopat c ety q
     ; hty <- lookupStd h c'
     ; return (TyInt,c') }

inferCopat _ _ (QPat _ _) = unimplementedErr "inferCopat"
inferCopat _ _ (QVar _ _) = unimplementedErr "inferCopat{qvar}"

-----------
-- check --
-----------

check :: Ctx -> Term -> Type -> Std ()
check _ (Let _ _ _) _ = unimplementedErr "check{Let}"
check c (Ann a aty) ty =
  case aty == ty of
    True -> check c a ty
    False -> typeErr ("expected type" <+> pp ty <+> "given" <+> pp aty)
check _ (Lit _) ty =
  case ty == TyInt of
    True -> return ()
    False -> typeErr ("expected type" <+> pp ty <+> "given" <+> pp TyInt)
check c (Add a b) ty =
  case ty == TyInt of
    True -> check c a TyInt >> check c b TyInt
    False -> typeErr ("expected type" <+> pp ty <+> "given" <+> pp TyInt)
check c (Var v) ty =
  do { ty' <- lookupStd v c
     ; case ty == ty' of
         True -> return ()
         False -> typeErr ("expected '" <+> pp v
                           <+> "' to have type" <+> pp ty) }
check c (Fix v t) ty = check ((v,ty):c) t ty
check c (Cons k) ty =
  do { ty' <- lookupStd k c
     ; case ty == ty' of
         True -> return ()
         False -> typeErr ("expected '" <+> pp k
                           <+> "' to have type" <+> pp ty) }
check c (Dest h) ty =
  do { ty' <- lookupStd h c
     ; case ty == ty' of
         True -> return ()
         False -> typeErr ("expected '" <+> pp h
                           <+> "' to have type" <+> pp ty) }
check c (App a b) ty =
  do { aty <- infer c a
     ; case aty of
         TyArr dom cod ->
           case cod == ty of
             True -> check c b dom
             False -> typeErr ("expected '" <+> pp a
                               <+> "' to have return type" <+> pp ty)
         _ -> typeErr ("must have a function type: " ++ pp a)
     }
check c (Case e alts) ty =
  do { ety <- infer c e
     ; alttys <- mapM (\(p,u) -> checkPat c p ety >>= \c' -> infer c' u) alts
     ; case all (== ty) alttys of
         True  -> return ()
         False -> typeErr ("alternatives do not have expected type" <+> pp ty)
     }
check _ (CoCase _) _ = error "check{CoCase}"
check c (Prompt t) ty =
  do { ty' <- infer c t
     ; case ty' == ty of
         True -> return ()
         False -> typeErr ("expected type" <+> pp ty <+> "given" <+> pp ty')
     }

{- checking patterns produces a new context that binds variables of some type.
-}
checkPat :: Ctx -> Pattern -> Type -> Std Ctx
checkPat c PWild        _ = return c
checkPat c (PVar v)     t = return ((v,t):c)
checkPat c (PCons k ps) ty =
  do { kty <- lookupStd k c
     ; case tyCodomain kty == ty of
         True ->
           case length ps == funArity kty of
             True  ->
               do { cs <- mapM (\(ty',p') -> checkPat c p' ty')
                               (zip (collectFunArgTys kty) ps)
                  ; return (mconcat cs <> c) }
             False -> typeErr ("constructor '" <> pp k
                               <> "' has arity" <+> show (funArity kty))
         False -> typeErr (pp k <+> "is not a constructor of type" <+> pp ty)
     }
  where collectFunArgTys :: Type -> [Type]
        collectFunArgTys (TyArr a b) = a : collectFunArgTys b
        collectFunArgTys x = [x]
        tyCodomain :: Type -> Type
        tyCodomain (TyArr _ b) = tyCodomain b
        tyCodomain t = t

--------------------------------------------------------------------------------
--                                 Utils                                      --
--------------------------------------------------------------------------------

mkContext :: [Decl] -> [(Variable,Type)]
mkContext [] = []
mkContext (d:ds) =
  (case d of
     Left neg -> map (\p -> (projName p, projType p))
                    (projections neg)
     Right pos -> map (\i -> (injName i, injType i)) (injections pos)
  ) <> (mkContext ds)

lookupDecl :: Variable -> [Decl] -> Maybe Decl
lookupDecl _ [] = Nothing
lookupDecl v ((Left d):ds) = case v == negTyName d of
                               True -> Just (Left d)
                               False -> lookupDecl v ds
lookupDecl v ((Right d):ds) = case v == posTyName d of
                               True -> Just (Right d)
                               False -> lookupDecl v ds

type Ctx = [(Variable,Type)]

lookupDatum :: Variable -> [Decl] -> Maybe Decl
lookupDatum _ [] = Nothing
lookupDatum h (Left  d:ds) =
  case lookupProjection h (projections d) of
    Just _ -> Just (Left d)
    Nothing -> lookupDatum h ds
lookupDatum k (Right d:ds) =
  case lookupInjection k (injections d) of
    Just _ -> Just (Right d)
    Nothing -> lookupDatum k ds

lookupProjection :: Variable -> [Projection] -> Maybe Projection
lookupProjection _ [] = Nothing
lookupProjection h (p:ps) = case projName p == h of
                             True -> Just p
                             False -> lookupProjection h ps

lookupInjection :: Variable -> [Injection] -> Maybe Injection
lookupInjection _ [] = Nothing
lookupInjection k (i:is) = case injName i == k of
                             True -> Just i
                             False -> lookupInjection k is
