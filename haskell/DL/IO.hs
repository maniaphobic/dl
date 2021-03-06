{-# LANGUAGE BangPatterns #-}
module DL.IO where

import DL.Syntax.Top
import DL.Syntax.Term
import DL.Parser.Parser
import DL.Parser.Lexer

--------------------------------------------------------------------------------
--                                 IO                                         --
--------------------------------------------------------------------------------

getProgram :: FilePath -> IO (Program Term)
getProgram fp =
  do { !tokens <- case fp of
                    "-" -> lexContents
                    _   -> lexFile fp
     ; case tokens of
         Left e -> error e
         Right ts ->
           case runParserM (parseProgram ts) emptyPState of
             Left e -> error e
             Right (p,_) -> return p
     }
