{-# LANGUAGE GADTs,
             DataKinds,
             RankNTypes #-}
module DualSyn where

import Debug.Trace
import Control.Monad.State
import Data.Monoid ((<>))

import KindSyn
import TypeSyn
import VariableSyn
import Utils


--------------------------------------------------------------------------------
--                             Top Level                                      --
--------------------------------------------------------------------------------

data Program t
  = Pgm
  { pgmDecls :: [Decl]
  , pgmTerm  :: t }

instance Pretty t => Pretty (Program t) where
  pp pgm = (stringmconcat "\n\n" . fmap pp . pgmDecls $ pgm)
        <> "\n\n"
        <> (pp . pgmTerm $ pgm)

flattenPgm :: Program Term -> Program FlatTerm
flattenPgm pgm = Pgm (pgmDecls pgm) (flatten . pgmTerm $ pgm)

type Decl = Either NegativeTyCons PositiveTyCons

instance (Pretty a,Pretty b) => Pretty (Either a b) where
  pp _ = ""

declArity :: Decl -> Int
declArity (Left d)  = length . negTyFVars $ d
declArity (Right d) = length . posTyFVars $ d

{- There is a special polarity type because positive and negative types are
   declared with the same structure, but we still need to keep them separate. -}
data Polarity = Positive | Negative
  deriving (Eq,Show)


--------------------------------------------------------------------------------
--                                 Terms                                      --
--------------------------------------------------------------------------------
{- Terms are parameterized over the type of pattern and copattern. This is
important because we only translate flat (co)patterns. -}
data Term where
  Let :: Variable -> Term -> Term -> Term

  -- ^ Number primitives
  Lit :: Int -> Term
  Add :: Term -> Term -> Term

  Var   :: Variable -> Term
  Fix   :: Variable -> Term -> Term
  App   :: Term -> Term -> Term

  Cons :: Variable -> Term
  Case :: Term -> [(Pattern,Term)] -> Term

  Dest :: Variable -> Term
  CoCase :: [(CoPattern,Term)] -> Term
  Prompt :: Term -> Term -- sets a point to delimit continuations
  deriving (Eq,Show)

instance Pretty Term where
  ppInd _ (Lit i)         = show i
  ppInd i (Add a b)       = (parens . ppInd i $ a)
                        <+> "+"
                        <+> (parens . ppInd i $ b)
  ppInd _ (Var s)         = s
  ppInd i (Fix s t)       = "fix" <+> s <+> "in" <-> indent i (ppInd (i+1) t)
  ppInd i (Let s a b)     = "let" <+> s <+> "=" <+> ppInd (i+1) a
                        <-> indent i ("in" <+> ppInd (i+1) b)
  ppInd i (App a b)       = (parens . ppInd i $ a) <+> (parens . ppInd i $ b)
  ppInd _ (Cons k)        = k
  ppInd i (Case t alts)   = "case"
                        <+> ppInd i t
                        <-> indent (i+1) "{"
                        <+> ( stringmconcat ("\n" <> (indent (i+1) "| "))
                            . fmap (\(p,u) -> pp p <+> "->" <+> ppInd (i+2) u)
                            $ alts)
                        <-> indent (i+1) "}"
  ppInd _ (Dest h)        = h
  ppInd i (CoCase [])     = "cocase {}"
  ppInd i (CoCase coalts) = "cocase"
                        <-> indent (i+1) "{ "
                        <>  ( stringmconcat ("\n" <> (indent (i+1) ", "))
                            . fmap (\(q,u) -> pp q <+> "->" <+> ppInd (i+2) u)
                            $ coalts)
                        <-> indent (i+1) "}"

{- `collectArgs` will recur down an application to find the constructor and its
   arguments -}
collectArgs :: Term -> Maybe (Variable,[Term])
collectArgs (App e t) = collectArgs e >>= \(k,ts) -> return (k,t:ts)
collectArgs (Cons k)  = return (k,[])
collectArgs _         = Nothing

{- `distributeArgs` will take a constructor and its arguments and construct a
   term applying the constructor to all of its arguments -}
distributeArgs :: (Variable,[Term]) -> Term
distributeArgs (k,ts) = foldl App (Cons k) ts


------------------
-- (Co)patterns --
------------------

{- Pattern -}
data Pattern where
  PWild :: Pattern
  PVar  :: Variable -> Pattern
  PCons :: Variable -> [Pattern] -> Pattern
  deriving (Eq,Show)

instance Pretty Pattern where
  pp PWild        = "_"
  pp (PVar s)     = s
  pp (PCons k ps) = k <+> (smconcat . fmap (parens . pp) $ ps)

{- Copatterns -}
{- NOTE: we often use 'q' for a copattern variables -}
data CoPattern where
  QHead :: CoPattern                          -- ^ the copattern matching the context
  QDest :: Variable -> CoPattern -> CoPattern -- ^ a specific destructor
  QPat  :: CoPattern -> Pattern -> CoPattern  -- ^ a copattern applied ot a pattern
  QVar  :: Variable -> CoPattern -> CoPattern -- ^ a covariable to bind continuations
  deriving (Eq,Show)

instance Pretty CoPattern where
  pp QHead       = "#"
  pp (QDest h q) = h <+> (parens . pp $ q)
  pp (QPat q p)  = (parens . pp $ q) <+> (parens . pp $ p)


-----------------------------
-- Some smart constructors --
-----------------------------

lam :: Variable -> Term -> Term
lam v t = CoCase [(QPat QHead (PVar v), t)]

--------------------------------------------------------------------------------
--                        Term Manipulations --
--------------------------------------------------------------------------------

{- Used in the context filling rules R-RecPat and R-RedDest, Takes a copattern and
returns (an optional new copattern with the inner most matchable pattern pulled
out and replace by head) and the inner most copattern -}

unplugCopattern :: CoPattern -> (Maybe CoPattern,CoPattern)
unplugCopattern QHead           = (Nothing, QHead)
unplugCopattern (QPat QHead p)  = (Nothing, (QPat QHead p))
unplugCopattern (QDest h QHead) = (Nothing, (QDest h QHead))
unplugCopattern (QDest h q)     = let (m,i) = unplugCopattern q in
                                  case m of
                                    Nothing -> (Just (QDest h QHead), i)
                                    Just q' -> (Just (QDest h q'), i)
unplugCopattern (QPat q p)      = let (m,i) = unplugCopattern q in
                                  case m of
                                    Nothing -> (Just (QPat QHead p), i)
                                    Just q' -> (Just (QPat q' p), i)

-- replace head with copattern in copattern
plugCopattern :: CoPattern -> CoPattern -> CoPattern
plugCopattern QHead       q' = q'
plugCopattern (QDest h q) q' = QDest h (plugCopattern q q')
plugCopattern (QPat q p)  q' = QPat (plugCopattern q q') p


{- `flattenPattern` will traverse a term, turning (co)case expressions with
   nested (co-)patterns in ones nesting (co)case expressions instead. This
   simplifies translation.

   An example of flattening a case:
   ```
   case (Pair (Pair 0 1) (Pair 1 2))
     { Pair (Pair w x) (Pair y z) -> w + x + y + z }
   ```
   ===>
   ```
   case (Pair 0 (Pair 1 2))
     { Pair p0 p1 ->
         case p0
           { Pair w x ->
               case p1
                { Pair y z -> w + x + y + z
                }
           }
     }
   ```

   An example of flattening a cocase:
   ```
   cocase { Fst # -> 0
          , Fst (Snd #) -> 1
          , Snd (Snd #) -> 2 }
   ```
   ===>
   ```
   cocase { Fst # -> 0
          , Snd # -> cocase { Fst # -> 1
                            , Snd # -> 2 } }
   ```
-}

fresh :: Variable -> State Int Variable
fresh v = do { n <- get
             ; put (succ n)
             ; return (v <> show n) }

flatten :: Term -> FlatTerm
flatten t = fst . runState (flatten' t) $ 0

flatten' :: Term -> State Int FlatTerm
flatten' (Let v a b) =
  FLet v <$> flatten' a <*> flatten' b
flatten' (Lit i) = return (FLit i)
flatten' (Add a b) = FAdd <$> flatten' a <*> flatten' b
flatten' (Var v) = return (FVar v)
flatten' (Fix v t) = FFix v <$> flatten' t
flatten' (App a b) = FApp <$> flatten' a <*> flatten' b
flatten' (Cons k) = return (FCons k)
flatten' (Dest h) = return (FDest h)
flatten' (Case t alts) =
  FCase <$> flatten' t <*> (flattenAlt . head $ alts) <*> return FFail
  where flattenAlt :: (Pattern,Term) -> State Int (FlatPattern,FlatTerm)
        flattenAlt (p,u) =
          do { u' <- flatten' u
             ; case p of
                 PVar v -> return (FlatPatVar v, u')
                 PCons k ps -> do { (vs,fs) <- unzip <$> mapM flattenPattern ps
                                  ; return (FlatPatCons k vs, foldr ($) u' fs) }
             }

        flattenPattern :: Pattern
                       -> State Int (Variable, FlatTerm -> FlatTerm)
        flattenPattern (PVar v) = return (v,id)
        flattenPattern (PCons k ps) =
          do { v <- fresh "p"
             ; (vs,fs) <- unzip <$> mapM flattenPattern ps
             ; return ( v
                      , \e -> FCase (FVar v)
                                    (FlatPatCons k vs,foldr ($) e fs)
                                    FFail)
             }

flatten' (CoCase ((QHead,u):_)) = flatten' u    -- R-QHead

flatten' (CoCase ((QPat QHead (PVar v),u):_)) = -- R-QPVar
  do { u' <- flatten' u
     ; return (FCoCase (FlatCopPat (FlatPatVar v), u') FFail) }

flatten' (CoCase ((QPat QHead p,u):coalts)) =   -- R-QPat
  do { v <- fresh "p"
     ; y <- fresh "y"
     ; let t = Case (Var v) [(p,u),(PVar y,CoCase coalts)]
     ; t' <- flatten' t
     ; return (FCoCase (FlatCopPat (FlatPatVar v), t') FFail)
     }

flatten' (CoCase ((QDest h QHead,u):coalts)) =  -- R-QDest
  do { u' <- flatten' u
     ; coalts' <- flatten' (CoCase coalts)
     ; return (FCoCase (FlatCopDest h,u') coalts')
     }

flatten' (CoCase ((q,u):coalts)) =              -- R-Rec
  flatten' (CoCase coalts) >>= \cocase' ->
  flatten' u >>= \u' ->
  case unplugCopattern q of
    (Just rest, QPat QHead p) ->
      do { v  <- fresh "coalt"
         ; let u' = CoCase [(rest,  u),(QHead, App (Var v) (invertPattern p))]
         ; u'' <- flatten' u'
         ; flatten' (Let v (CoCase coalts) (CoCase [(QPat QHead p, u'),(QHead,Var v)]))
         }
    (Just rest, QDest h QHead) ->
      do { v  <- fresh "coalt"
         ; u' <- flatten' ( CoCase [(rest,  u)
                                   ,(QHead, App (Dest h) (Var v))
                                   ]
                           )
         ; return (FLet v cocase' (FCoCase (FlatCopDest h, u') (FVar v))) }
    x -> error $ "TODO flatten'{" <> show x <> "}"

flatten' (CoCase []) = return FFail -- R-Empty

invertPattern :: Pattern -> Term
invertPattern PWild = error "cannot invert wildcard"
invertPattern (PVar v) = Var v
invertPattern (PCons k ps) = distributeArgs (k,fmap invertPattern ps)



--------------------------------------------------------------------------------
--                              Flat Terms                                    --
--------------------------------------------------------------------------------
{- FlatTerms where added because in addition to having only flat (co)patterns,
they also have (co)case statements that contain defaults.

FlatTerms are a subset of Terms. -}
data FlatTerm where
  FLet :: Variable -> FlatTerm -> FlatTerm -> FlatTerm

  -- ^ Number primitives
  FLit :: Int -> FlatTerm
  FAdd :: FlatTerm -> FlatTerm -> FlatTerm

  FVar :: Variable -> FlatTerm
  FFix :: Variable -> FlatTerm -> FlatTerm
  FApp :: FlatTerm -> FlatTerm -> FlatTerm

  FCons :: Variable -> FlatTerm

  FCase :: FlatTerm               -- ^ Interrogated term
        -> (FlatPattern,FlatTerm) -- ^ Alternative
        -> FlatTerm               -- ^ Default case
        -> FlatTerm

  FDest :: Variable -> FlatTerm

  FCoCase :: (FlatCopattern,FlatTerm) -- ^ Coalternative
          -> FlatTerm                 -- ^ Default case
          -> FlatTerm

  FFail :: FlatTerm
  deriving (Eq,Show)

instance Pretty FlatTerm where
  ppInd _ (FLit i)         = show i
  ppInd i (FAdd a b)       = (parens . ppInd i $ a)
                         <+> "+"
                         <+> (parens . ppInd i $ b)
  ppInd _ (FVar s)         = s
  ppInd i (FFix s t)       = "fix" <+> s <+> "in" <-> indent i (ppInd (i+1) t)
  ppInd i (FLet s a b)     = "let" <+> s <+> "=" <+> ppInd (i+1) a
                         <-> indent i ("in" <+> ppInd (i+1) b)
  ppInd i (FApp a b)       = (parens . ppInd i $ a) <+> (parens . ppInd i $ b)
  ppInd _ (FCons k)        = k
  ppInd i (FCase t (p,u) d) = ("case" <+> ppInd i t)
                          <-> (indent (i+1) "{" <+> pp p <+> "->"
                               <+> (ppInd (i+2) u))
                          <-> (indent (i+1) "|" <+> "_ ->"
                               <+> (ppInd (i+2) d))
                          <-> (indent (i+1) "}")
  ppInd _ (FDest h)        = h
  ppInd i (FCoCase (q,u) d) = "cocase"
                          <-> (indent (i+1) "{" <+> pp q <+> "->"
                               <+> (ppInd (i+2) u))
                          <-> (indent (i+1) "," <+> "# ->"
                               <+> (ppInd (i+2) d))
                          <-> (indent (i+1) "}")
  ppInd _ FFail = "cocase {}"

data FlatPattern where
  FlatPatVar  :: Variable -> FlatPattern
  FlatPatCons :: Variable -> [Variable] -> FlatPattern
  deriving (Eq,Show)

instance Pretty FlatPattern where
  pp (FlatPatVar s)     = s
  pp (FlatPatCons k vs) = smconcat (k:vs)

data FlatCopattern where
  FlatCopDest :: Variable -> FlatCopattern
  FlatCopPat  :: FlatPattern -> FlatCopattern
  deriving (Eq,Show)

instance Pretty FlatCopattern where
  pp (FlatCopDest h)             = h <+> "#"
  pp (FlatCopPat (FlatPatVar v)) = "#" <+> v
  pp (FlatCopPat k)              = "#" <+> (parens . pp $ k)
