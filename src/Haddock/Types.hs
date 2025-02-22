{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE DeriveDataTypeable, DeriveFunctor #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Types
-- Copyright   :  (c) Simon Marlow 2003-2006,
--                    David Waern  2006-2009
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskellorg
-- Stability   :  experimental
-- Portability :  portable
--
-- Types that are commonly used through-out Haddock. Some of the most
-- important types are defined here, like 'Interface' and 'DocName'.
-----------------------------------------------------------------------------
module Haddock.Types (
  module Haddock.Types
  , HsDocString, LHsDocString
 ) where


import Control.Exception
import Control.Arrow
import Data.Typeable
import Data.Map (Map)
import qualified Data.Map as Map
import GHC hiding (NoLink)


-----------------------------------------------------------------------------
-- * Convenient synonyms
-----------------------------------------------------------------------------


type IfaceMap      = Map Module Interface
type InstIfaceMap  = Map Module InstalledInterface
type DocMap        = Map Name (Doc DocName)
type SrcMap        = Map PackageId FilePath
type Decl          = LHsDecl Name
type GhcDocHdr     = Maybe LHsDocString
type DocPaths      = (FilePath, Maybe FilePath) -- paths to HTML and sources


-----------------------------------------------------------------------------
-- * Interface
-----------------------------------------------------------------------------


-- | 'Interface' holds all information used to render a single Haddock page.
-- It represents the /interface/ of a module. The core business of Haddock
-- lies in creating this structure. Note that the record contains some fields
-- that are only used to create the final record, and that are not used by the
-- backends.
data Interface = Interface
  {
    -- | The module behind this interface.
    ifaceMod             :: Module

    -- | Original file name of the module.
  , ifaceOrigFilename    :: FilePath

    -- | Textual information about the module.
  , ifaceInfo            :: !(HaddockModInfo Name)

    -- | Documentation header.
  , ifaceDoc             :: !(Maybe (Doc Name))

    -- | Documentation header with cross-reference information.
  , ifaceRnDoc           :: Maybe (Doc DocName)

    -- | Haddock options for this module (prune, ignore-exports, etc).
  , ifaceOptions         :: ![DocOption]

    -- | Declarations originating from the module. Excludes declarations without
    -- names (instances and stand-alone documentation comments). Includes
    -- names of subordinate declarations mapped to their parent declarations.
  , ifaceDeclMap         :: Map Name DeclInfo

    -- | Documentation of declarations originating from the module (including
    -- subordinates).
  , ifaceRnDocMap        :: Map Name (DocForDecl DocName)

  , ifaceSubMap          :: Map Name [Name]

  , ifaceExportItems     :: ![ExportItem Name]
  , ifaceRnExportItems   :: [ExportItem DocName]

    -- | All names exported by the module.
  , ifaceExports         :: ![Name]

    -- | All \"visible\" names exported by the module.
    -- A visible name is a name that will show up in the documentation of the
    -- module.
  , ifaceVisibleExports  :: ![Name]

    -- | Instances exported by the module.
  , ifaceInstances       :: ![Instance]

    -- | Documentation of instances defined in the module.
  , ifaceInstanceDocMap  :: Map Name (Doc Name)

    -- | The number of haddockable and haddocked items in the module, as a
    -- tuple. Haddockable items are the exports and the module itself.
  , ifaceHaddockCoverage  :: (Int,Int)
  }


-- | A subset of the fields of 'Interface' that we store in the interface
-- files.
data InstalledInterface = InstalledInterface
  {
    -- | The module represented by this interface.
    instMod            :: Module

    -- | Textual information about the module.
  , instInfo           :: HaddockModInfo Name

    -- | Documentation of declarations originating from the module (including
    -- subordinates).
  , instDocMap         :: Map Name (DocForDecl Name)

    -- | All names exported by this module.
  , instExports        :: [Name]

    -- | All \"visible\" names exported by the module.
    -- A visible name is a name that will show up in the documentation of the
    -- module.
  , instVisibleExports :: [Name]

    -- | Haddock options for this module (prune, ignore-exports, etc).
  , instOptions        :: [DocOption]

  , instSubMap         :: Map Name [Name]
  }


-- | Convert an 'Interface' to an 'InstalledInterface'
toInstalledIface :: Interface -> InstalledInterface
toInstalledIface interface = InstalledInterface
  { instMod            = ifaceMod            interface
  , instInfo           = ifaceInfo           interface
  , instDocMap         = fmap unrenameDocForDecl $ ifaceRnDocMap interface
  , instExports        = ifaceExports        interface
  , instVisibleExports = ifaceVisibleExports interface
  , instOptions        = ifaceOptions        interface
  , instSubMap         = ifaceSubMap         interface
  }


-----------------------------------------------------------------------------
-- * Export items & declarations
-----------------------------------------------------------------------------


data ExportItem name

  -- | An exported declaration.
  = ExportDecl
      {
        -- | A declaration.
        expItemDecl :: LHsDecl name

        -- | Maybe a doc comment, and possibly docs for arguments (if this
        -- decl is a function or type-synonym).
      , expItemMbDoc :: DocForDecl name

        -- | Subordinate names, possibly with documentation.
      , expItemSubDocs :: [(name, DocForDecl name)]

        -- | Instances relevant to this declaration, possibly with
        -- documentation.
      , expItemInstances :: [DocInstance name]
      }

  -- | An exported entity for which we have no documentation (perhaps because it
  -- resides in another package).
  | ExportNoDecl
      { expItemName :: name

        -- | Subordinate names.
      , expItemSubs :: [name]
      }

  -- | A section heading. 
  | ExportGroup
      {
        -- | Section level (1, 2, 3, ...).
        expItemSectionLevel :: Int

        -- | Section id (for hyperlinks).
      , expItemSectionId :: String

        -- | Section heading text.
      , expItemSectionText :: Doc name
      }

  -- | Some documentation.
  | ExportDoc (Doc name)

  -- | A cross-reference to another module.
  | ExportModule Module


-- | A declaration that may have documentation, including its subordinates,
-- which may also have documentation.
type DeclInfo = (Decl, DocForDecl Name, [(Name, DocForDecl Name)])


-- | Arguments and result are indexed by Int, zero-based from the left,
-- because that's the easiest to use when recursing over types.
type FnArgsDoc name = Map Int (Doc name)
type DocForDecl name = (Maybe (Doc name), FnArgsDoc name)


noDocForDecl :: DocForDecl name
noDocForDecl = (Nothing, Map.empty)


unrenameDocForDecl :: DocForDecl DocName -> DocForDecl Name
unrenameDocForDecl (mbDoc, fnArgsDoc) =
    (fmap unrenameDoc mbDoc, fmap unrenameDoc fnArgsDoc)


-----------------------------------------------------------------------------
-- * Cross-referencing
-----------------------------------------------------------------------------


-- | Type of environment used to cross-reference identifiers in the syntax.
type LinkEnv = Map Name Module


-- | Extends 'Name' with cross-reference information.
data DocName
  = Documented Name Module
     -- ^ This thing is part of the (existing or resulting)
     -- documentation. The 'Module' is the preferred place
     -- in the documentation to refer to.
  | Undocumented Name
     -- ^ This thing is not part of the (existing or resulting)
     -- documentation, as far as Haddock knows.
  deriving Eq


instance NamedThing DocName where
  getName (Documented name _) = name
  getName (Undocumented name) = name


-----------------------------------------------------------------------------
-- * Instances
-----------------------------------------------------------------------------


-- | An instance head that may have documentation.
type DocInstance name = (InstHead name, Maybe (Doc name))


-- | The head of an instance. Consists of a context, a class name and a list
-- of instance types.
type InstHead name = ([HsType name], name, [HsType name])


-----------------------------------------------------------------------------
-- * Documentation comments
-----------------------------------------------------------------------------


type LDoc id = Located (Doc id)


data Doc id
  = DocEmpty
  | DocAppend (Doc id) (Doc id)
  | DocString String
  | DocParagraph (Doc id)
  | DocIdentifier [id]
  | DocModule String
  | DocEmphasis (Doc id)
  | DocMonospaced (Doc id)
  | DocUnorderedList [Doc id]
  | DocOrderedList [Doc id]
  | DocDefList [(Doc id, Doc id)]
  | DocCodeBlock (Doc id)
  | DocURL String
  | DocPic String
  | DocAName String
  | DocExamples [Example]
  deriving (Eq, Show, Functor)


unrenameDoc :: Doc DocName -> Doc Name
unrenameDoc = fmap getName


data Example = Example
  { exampleExpression :: String
  , exampleResult     :: [String]
  } deriving (Eq, Show)


exampleToString :: Example -> String
exampleToString (Example expression result) =
    ">>> " ++ expression ++ "\n" ++  unlines result


data DocMarkup id a = Markup
  { markupEmpty         :: a
  , markupString        :: String -> a
  , markupParagraph     :: a -> a
  , markupAppend        :: a -> a -> a
  , markupIdentifier    :: [id] -> a
  , markupModule        :: String -> a
  , markupEmphasis      :: a -> a
  , markupMonospaced    :: a -> a
  , markupUnorderedList :: [a] -> a
  , markupOrderedList   :: [a] -> a
  , markupDefList       :: [(a,a)] -> a
  , markupCodeBlock     :: a -> a
  , markupURL           :: String -> a
  , markupAName         :: String -> a
  , markupPic           :: String -> a
  , markupExample       :: [Example] -> a
  }


data HaddockModInfo name = HaddockModInfo
  { hmi_description :: Maybe (Doc name)
  , hmi_portability :: Maybe String
  , hmi_stability   :: Maybe String
  , hmi_maintainer  :: Maybe String
  , hmi_safety      :: Maybe String
  }


emptyHaddockModInfo :: HaddockModInfo a
emptyHaddockModInfo = HaddockModInfo
  { hmi_description = Nothing
  , hmi_portability = Nothing
  , hmi_stability   = Nothing
  , hmi_maintainer  = Nothing
  , hmi_safety      = Nothing
  }


-----------------------------------------------------------------------------
-- * Options
-----------------------------------------------------------------------------


{-! for DocOption derive: Binary !-}
-- | Source-level options for controlling the documentation.
data DocOption
  = OptHide            -- ^ This module should not appear in the docs.
  | OptPrune
  | OptIgnoreExports   -- ^ Pretend everything is exported.
  | OptNotHome         -- ^ Not the best place to get docs for things
                       -- exported by this module.
  deriving (Eq, Show)


-- | Option controlling how to qualify names
data Qualification
  = NoQual                       -- ^ Never qualify any names.
  | FullQual                     -- ^ Qualify all names fully.
  | LocalQual (Maybe Module)     -- ^ Qualify all imported names fully.
  | RelativeQual (Maybe Module)  -- ^ Like local, but strip module prefix.
                                 --   from modules in the same hierarchy.


-----------------------------------------------------------------------------
-- * Error handling
-----------------------------------------------------------------------------


-- A monad which collects error messages, locally defined to avoid a dep on mtl


type ErrMsg = String
newtype ErrMsgM a = Writer { runWriter :: (a, [ErrMsg]) }


instance Functor ErrMsgM where
        fmap f (Writer (a, msgs)) = Writer (f a, msgs)


instance Monad ErrMsgM where
        return a = Writer (a, [])
        m >>= k  = Writer $ let
                (a, w)  = runWriter m
                (b, w') = runWriter (k a)
                in (b, w ++ w')


tell :: [ErrMsg] -> ErrMsgM ()
tell w = Writer ((), w)


-- Exceptions


-- | Haddock's own exception type.
data HaddockException = HaddockException String deriving Typeable


instance Show HaddockException where
  show (HaddockException str) = str


throwE :: String -> a
instance Exception HaddockException
throwE str = throw (HaddockException str)


-- In "Haddock.Interface.Create", we need to gather
-- @Haddock.Types.ErrMsg@s a lot, like @ErrMsgM@ does,
-- but we can't just use @GhcT ErrMsgM@ because GhcT requires the
-- transformed monad to be MonadIO.
newtype ErrMsgGhc a = WriterGhc { runWriterGhc :: (Ghc (a, [ErrMsg])) }
--instance MonadIO ErrMsgGhc where
--  liftIO = WriterGhc . fmap (\a->(a,[])) liftIO
--er, implementing GhcMonad involves annoying ExceptionMonad and
--WarnLogMonad classes, so don't bother.
liftGhcToErrMsgGhc :: Ghc a -> ErrMsgGhc a
liftGhcToErrMsgGhc = WriterGhc . fmap (\a->(a,[]))
liftErrMsg :: ErrMsgM a -> ErrMsgGhc a
liftErrMsg = WriterGhc . return . runWriter
--  for now, use (liftErrMsg . tell) for this
--tell :: [ErrMsg] -> ErrMsgGhc ()
--tell msgs = WriterGhc $ return ( (), msgs )


instance Functor ErrMsgGhc where
  fmap f (WriterGhc x) = WriterGhc (fmap (first f) x)


instance Monad ErrMsgGhc where
  return a = WriterGhc (return (a, []))
  m >>= k = WriterGhc $ runWriterGhc m >>= \ (a, msgs1) ->
               fmap (second (msgs1 ++)) (runWriterGhc (k a))
