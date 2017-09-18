module Utils where

import Data.Monoid

class Pretty a where
  {-# MINIMAL pp #-}
  pp :: a -> String
  ppInd :: Int -> a -> String
  pp = ppInd 0

pprint :: Pretty a => a -> IO ()
pprint = putStrLn . pp

infixr 0 <+>
(<+>) :: String -> String -> String
a <+> b = a <> " " <> b

infixr 1 <->
(<->) :: String -> String -> String
a <-> b = a <> "\n" <> b

indent :: Int -> String -> String
indent lvl s = replicate (lvl*2) ' ' <> s

stringmconcat :: String -> [String] -> String
stringmconcat _ []     = []
stringmconcat _ (x:[]) = x
stringmconcat s (x:xs) = x <> s <> stringmconcat s xs

{- concatenates terms with a space between them -}
smconcat :: [String] -> String
smconcat = stringmconcat " "

{- concatenates terms with a newline between them -}
vmconcat :: [String] -> String
vmconcat = stringmconcat "\n"

ppPrec :: Int -> Int -> String -> String
ppPrec p p' s = case p > p' of
                  True -> parens s
                  False -> s

parens :: String -> String
parens s = "(" <> s <> ")"
