-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Backends.Hoogle
-- Copyright   :  (c) Neil Mitchell 2006-2008
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- Write out Hoogle compatible documentation
-- http://www.haskell.org/hoogle/
-----------------------------------------------------------------------------
module Haddock.Backends.Hoogle ( 
    ppHoogle
  ) where


import Haddock.GhcUtils
import Haddock.Types
import Haddock.Utils hiding (out)
import GHC
import Outputable

import Data.Char
import Data.List
import Data.Maybe
import System.FilePath
import System.IO

prefix :: [String]
prefix = ["-- Hoogle documentation, generated by Haddock"
         ,"-- See Hoogle, http://www.haskell.org/hoogle/"
         ,""]


ppHoogle :: String -> String -> String -> Maybe (Doc RdrName) -> [Interface] -> FilePath -> IO ()
ppHoogle package version synopsis prologue ifaces odir = do
    let filename = package ++ ".txt"
        contents = prefix ++
                   docWith (drop 2 $ dropWhile (/= ':') synopsis) prologue ++
                   ["@package " ++ package] ++
                   ["@version " ++ version | version /= ""] ++
                   concat [ppModule i | i <- ifaces, OptHide `notElem` ifaceOptions i]
    h <- openFile (odir </> filename) WriteMode
    hSetEncoding h utf8
    hPutStr h (unlines contents)
    hClose h

ppModule :: Interface -> [String]
ppModule iface = "" : doc (ifaceDoc iface) ++
                 ["module " ++ moduleString (ifaceMod iface)] ++
                 concatMap ppExport (ifaceExportItems iface) ++
                 concatMap ppInstance (ifaceInstances iface)


---------------------------------------------------------------------
-- Utility functions

dropHsDocTy :: HsType a -> HsType a
dropHsDocTy = f
    where
        g (L src x) = L src (f x)
        f (HsForAllTy a b c d) = HsForAllTy a b c (g d)
        f (HsBangTy a b) = HsBangTy a (g b)
        f (HsAppTy a b) = HsAppTy (g a) (g b)
        f (HsFunTy a b) = HsFunTy (g a) (g b)
        f (HsListTy a) = HsListTy (g a)
        f (HsPArrTy a) = HsPArrTy (g a)
        f (HsTupleTy a b) = HsTupleTy a (map g b)
        f (HsOpTy a b c) = HsOpTy (g a) b (g c)
        f (HsParTy a) = HsParTy (g a)
        f (HsKindSig a b) = HsKindSig (g a) b
        f (HsDocTy a _) = f $ unL a
        f x = x

outHsType :: OutputableBndr a => HsType a -> String
outHsType = out . dropHsDocTy


makeExplicit :: HsType a -> HsType a
makeExplicit (HsForAllTy _ a b c) = HsForAllTy Explicit a b c
makeExplicit x = x

makeExplicitL :: LHsType a -> LHsType a
makeExplicitL (L src x) = L src (makeExplicit x)


dropComment :: String -> String
dropComment (' ':'-':'-':' ':_) = []
dropComment (x:xs) = x : dropComment xs
dropComment [] = []


out :: Outputable a => a -> String
out = f . unwords . map (dropWhile isSpace) . lines . showSDocUnqual . ppr
    where
        f xs | " <document comment>" `isPrefixOf` xs = f $ drop 19 xs
        f (x:xs) = x : f xs
        f [] = []


operator :: String -> String
operator (x:xs) | not (isAlphaNum x) && x `notElem` "_' ([{" = "(" ++ x:xs ++ ")"
operator x = x


---------------------------------------------------------------------
-- How to print each export

ppExport :: ExportItem Name -> [String]
ppExport (ExportDecl decl dc subdocs _) = doc (fst dc) ++ f (unL decl)
    where
        f (TyClD d@TyData{}) = ppData d subdocs
        f (TyClD d@ClassDecl{}) = ppClass d
        f (TyClD d@TySynonym{}) = ppSynonym d
        f (ForD (ForeignImport name typ _ _)) = ppSig $ TypeSig [name] typ
        f (ForD (ForeignExport name typ _ _)) = ppSig $ TypeSig [name] typ
        f (SigD sig) = ppSig sig
        f _ = []
ppExport _ = []


ppSig :: Sig Name -> [String]
ppSig (TypeSig names sig) = [operator prettyNames ++ " :: " ++ outHsType typ]
    where
        prettyNames = concat . intersperse ", " $ map out names
        typ = case unL sig of
                   HsForAllTy Explicit a b c -> HsForAllTy Implicit a b c
                   x -> x
ppSig _ = []


ppSynonym :: TyClDecl Name -> [String]
ppSynonym x = [out x]


-- note: does not yet output documentation for class methods
ppClass :: TyClDecl Name -> [String]
ppClass x = out x{tcdSigs=[]} :
            concatMap (ppSig . addContext . unL) (tcdSigs x)
    where
        addContext (TypeSig name (L l sig)) = TypeSig name (L l $ f sig)
        addContext _ = error "expected TypeSig"

        f (HsForAllTy a b con d) = HsForAllTy a b (reL (context : unLoc con)) d
        f t = HsForAllTy Implicit [] (reL [context]) (reL t)

        context = nlHsTyConApp (unL $ tcdLName x)
            (map (reL . HsTyVar . hsTyVarName . unL) (tcdTyVars x))


ppInstance :: Instance -> [String]
ppInstance x = [dropComment $ out x]


ppData :: TyClDecl Name -> [(Name, DocForDecl Name)] -> [String]
ppData x subdocs = showData x{tcdCons=[],tcdDerivs=Nothing} :
                   concatMap (ppCtor x subdocs . unL) (tcdCons x)
    where
        -- GHC gives out "data Bar =", we want to delete the equals
        -- also writes data : a b, when we want data (:) a b
        showData d = unwords $ map f $ if last xs == "=" then init xs else xs
            where
                xs = words $ out d
                nam = out $ tcdLName d
                f w = if w == nam then operator nam else w

-- | for constructors, and named-fields...
lookupCon :: [(Name, DocForDecl Name)] -> Located Name -> Maybe (Doc Name)
lookupCon subdocs (L _ name) = case lookup name subdocs of
  Just (d, _) -> d
  _ -> Nothing

ppCtor :: TyClDecl Name -> [(Name, DocForDecl Name)] -> ConDecl Name -> [String]
ppCtor dat subdocs con = doc (lookupCon subdocs (con_name con))
                         ++ f (con_details con)
    where
        f (PrefixCon args) = [typeSig name $ args ++ [resType]]
        f (InfixCon a1 a2) = f $ PrefixCon [a1,a2]
        f (RecCon recs) = f (PrefixCon $ map cd_fld_type recs) ++ concat
                          [doc (lookupCon subdocs (cd_fld_name r)) ++
                           [out (unL $ cd_fld_name r) `typeSig` [resType, cd_fld_type r]]
                          | r <- recs]

        funs = foldr1 (\x y -> reL $ HsFunTy (makeExplicitL x) (makeExplicitL y))
        apps = foldl1 (\x y -> reL $ HsAppTy x y)

        typeSig nm flds = operator nm ++ " :: " ++ outHsType (makeExplicit $ unL $ funs flds)
        name = out $ unL $ con_name con

        resType = case con_res con of
            ResTyH98 -> apps $ map (reL . HsTyVar) $ unL (tcdLName dat) : [hsTyVarName v | v@UserTyVar {} <- map unL $ tcdTyVars dat]
            ResTyGADT x -> x


---------------------------------------------------------------------
-- DOCUMENTATION

doc :: Outputable o => Maybe (Doc o) -> [String]
doc = docWith ""


docWith :: Outputable o => String -> Maybe (Doc o) -> [String]
docWith [] Nothing = []
docWith header d = ("":) $ zipWith (++) ("-- | " : repeat "--   ") $
    [header | header /= ""] ++ ["" | header /= "" && isJust d] ++
    maybe [] (showTags . markup markupTag) d


data Tag = TagL Char [Tags] | TagP Tags | TagPre Tags | TagInline String Tags | Str String
           deriving Show

type Tags = [Tag]

box :: (a -> b) -> a -> [b]
box f x = [f x]

str :: String -> [Tag]
str a = [Str a]

-- want things like paragraph, pre etc to be handled by blank lines in the source document
-- and things like \n and \t converted away
-- much like blogger in HTML mode
-- everything else wants to be included as tags, neatly nested for some (ul,li,ol)
-- or inlne for others (a,i,tt)
-- entities (&,>,<) should always be appropriately escaped

markupTag :: Outputable o => DocMarkup o [Tag]
markupTag = Markup {
  markupParagraph     = box TagP,
  markupEmpty         = str "",
  markupString        = str,
  markupAppend        = (++),
  markupIdentifier    = box (TagInline "a") . str . out . head,
  markupModule        = box (TagInline "a") . str,
  markupEmphasis      = box (TagInline "i"),
  markupMonospaced    = box (TagInline "tt"),
  markupPic           = const $ str " ",
  markupUnorderedList = box (TagL 'u'),
  markupOrderedList   = box (TagL 'o'),
  markupDefList       = box (TagL 'u') . map (\(a,b) -> TagInline "i" a : Str " " : b),
  markupCodeBlock     = box TagPre,
  markupURL           = box (TagInline "a") . str,
  markupAName         = const $ str "",
  markupExample       = box TagPre . str . unlines . map exampleToString
  }


showTags :: [Tag] -> [String]
showTags = intercalate [""] . map showBlock


showBlock :: Tag -> [String]
showBlock (TagP xs) = showInline xs
showBlock (TagL t xs) = ['<':t:"l>"] ++ mid ++ ['<':'/':t:"l>"]
    where mid = concatMap (showInline . box (TagInline "li")) xs
showBlock (TagPre xs) = ["<pre>"] ++ showPre xs ++ ["</pre>"]
showBlock x = showInline [x]


asInline :: Tag -> Tags
asInline (TagP xs) = xs
asInline (TagPre xs) = [TagInline "pre" xs]
asInline (TagL t xs) = [TagInline (t:"l") $ map (TagInline "li") xs]
asInline x = [x]


showInline :: [Tag] -> [String]
showInline = unwordsWrap 70 . words . concatMap f
    where
        fs = concatMap f
        f (Str x) = escape x
        f (TagInline s xs) = "<"++s++">" ++ (if s == "li" then trim else id) (fs xs) ++ "</"++s++">"
        f x = fs $ asInline x

        trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse


showPre :: [Tag] -> [String]
showPre = trimFront . trimLines . lines . concatMap f
    where
        trimLines = dropWhile null . reverse . dropWhile null . reverse
        trimFront xs = map (drop i) xs
            where
                ns = [length a | x <- xs, let (a,b) = span isSpace x, b /= ""]
                i = if null ns then 0 else minimum ns

        fs = concatMap f
        f (Str x) = escape x
        f (TagInline s xs) = "<"++s++">" ++ fs xs ++ "</"++s++">"
        f x = fs $ asInline x


unwordsWrap :: Int -> [String] -> [String]
unwordsWrap n = f n []
    where
        f _ s [] = [g s | s /= []]
        f i s (x:xs) | nx > i = g s : f (n - nx - 1) [x] xs
                     | otherwise = f (i - nx - 1) (x:s) xs
            where nx = length x

        g = unwords . reverse


escape :: String -> String
escape = concatMap f
    where
        f '<' = "&lt;"
        f '>' = "&gt;"
        f '&' = "&amp;"
        f x = [x]
