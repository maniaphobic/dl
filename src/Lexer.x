{
module Lexer (lexFile, lexContents, Token(..)) where
}

%wrapper "basic"

$digit = 0-9
$alpha = [a-zA-Z]

tokens :-

  $white+    ;
  "--".*     ;
  $digit+    { TokLit . read }
  Int        { const TokInt }
  \+         { const TokPlus }
  codata     { const TokCodata }
  data       { const TokData }
  cocase     { const TokCocase }
  case       { const TokCase }
  fix        { const TokFix }
  let        { const TokLet }
  =          { const TokEq }
  in         { const TokIn }
  \#         { const TokHash }
  □          { const TokBox }
  _          { const TokUnderscore }
  \->        { const TokArr }
  \{         { const TokLBrace }
  \}         { const TokRBrace }
  \(         { const TokLParen }
  \)         { const TokRParen }
  \[         { const TokLBrack }
  \]         { const TokRBrack }
  \,         { const TokComma }
  \|         { const TokMid }
  \:         { const TokColon }
  $alpha+    { TokString }

{
data Token
  = TokLit Int
  | TokInt
  | TokPlus
  | TokString String
  | TokCodata
  | TokData
  | TokCase
  | TokCocase
  | TokFix
  | TokLet
  | TokEq
  | TokIn
  | TokHash
  | TokBox
  | TokUnderscore
  | TokArr
  | TokLBrace
  | TokRBrace
  | TokLParen
  | TokRParen
  | TokLBrack
  | TokRBrack
  | TokComma
  | TokMid
  | TokColon
  deriving (Eq,Show)

lexFile :: FilePath -> IO [Token]
lexFile fp = alexScanTokens <$> readFile fp

lexContents :: IO [Token]
lexContents = alexScanTokens <$> getContents
}
