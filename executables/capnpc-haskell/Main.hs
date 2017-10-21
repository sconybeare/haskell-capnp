{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}
module Main (main) where

import Control.Monad            (void, (>=>))
import Control.Monad.Catch.Pure (CatchT(..))
import Control.Monad.Quota      (Quota(..), evalQuotaT)
import Control.Monad.Writer     (MonadWriter, Writer, runWriterT, tell)
import Data.ByteString.UTF8     (toString)
import Data.CapNProto.Message   (Message, decode)
import Data.DList               (DList)
import Data.Functor.Identity    (Identity(..))
import Data.List                (intersperse)
import Data.Monoid              (mconcat, (<>))
import Data.String              (fromString)
import Namespace
import System.Directory         (createDirectoryIfMissing)
import System.FilePath          (takeDirectory)
import Text.Printf              (printf)

import qualified Data.ByteString                                                   as BS
import qualified Data.CapNProto.BasicTypes                                         as BT
import qualified Data.CapNProto.List                                               as List
import qualified Data.CapNProto.Untyped                                            as U
import qualified Data.DList                                                        as DList
import qualified Data.Map.Strict                                                   as M
import qualified Language.CapNProto.TH                                             as CTH
import qualified Language.Haskell.TH                                               as TH
import qualified Schema.CapNProto.Reader.Schema                                    as Schema
import qualified Schema.CapNProto.Reader.Schema.CodeGeneratorRequest               as CGR
import qualified Schema.CapNProto.Reader.Schema.CodeGeneratorRequest.RequestedFile as ReqFile
import qualified Schema.CapNProto.Reader.Schema.Node                               as Node
import qualified Schema.CapNProto.Reader.Schema.Node.NestedNode                    as NN

type BS = BS.ByteString

type NodeMap = M.Map Node.Id (Schema.Node BS)

newtype GenAcc = GenAcc (M.Map NS (DList TH.DecsQ))

instance Monoid GenAcc where
    mempty = GenAcc $ M.empty
    mappend (GenAcc l) (GenAcc r) = GenAcc $ M.unionWith mappend l r

emit :: MonadWriter GenAcc m => NS -> TH.DecsQ -> m ()
emit k v = tell $ GenAcc $ M.singleton k (DList.singleton v)

type Generator a = CatchT (Writer GenAcc) a

buildNodeMap :: List.ListOf BS (Schema.Node BS) -> Generator NodeMap
buildNodeMap = List.foldl addNode M.empty
  where
    addNode m node = do
        nodeId <- Node.id node
        return $ M.insert nodeId node m

genModule :: NodeMap -> CGR.RequestedFile BS -> Generator ()
genModule nodeMap (ReqFile.id -> Right id) = do
    let Just node = M.lookup id nodeMap

    -- First, verify that the node in question is actually a file:
    Node.File <- Node.union_ node

    Just nn <- Node.nestedNodes node
    -- We put everything in a module named Schema.CapNProto.Reader.X<fileId>.
    -- this makes module names deterministic, without annotations, regardless
    -- of where files are actually loaded from. We can in the future generate
    -- aliases that re-export these modules from friendlier names, but doing it
    -- this way means we don't have to worry about a lot of the awkwardness re:
    -- locating packages that crops up in other languages.
    List.mapM_ (genNestedNode nodeMap [fromString $ 'X' : printf "%08x" id]) nn

genNestedNode :: NodeMap -> NS -> Node.NestedNode BS -> Generator ()
genNestedNode nodeMap ns nestedNode = do
    Just name <- NN.name nestedNode
    id <- NN.id nestedNode
    let Just node = M.lookup id nodeMap
    genNode nodeMap ns node name
    Just nn <- Node.nestedNodes node
    List.mapM_ (genNestedNode nodeMap (name:ns)) nn

genNode :: NodeMap -> NS -> Schema.Node BS -> (BT.Text BS) -> Generator ()
genNode nodeMap ns node (BT.Text name) = case Node.union_ node of
    Right (Node.Struct struct) -> do
        emit ns (CTH.mkStructWrappers [toString name])
    _ -> return ()

genReq :: Message BS.ByteString -> Generator ()
genReq (CGR.root_ -> Right (split CGR.nodes CGR.requestedFiles ->
                            (Right (Just nodes), Right (Just reqFiles)))) = do
    nodeMap <- buildNodeMap nodes
    List.mapM_ (genModule nodeMap) reqFiles
split f g x = (f x, g x)

mkSrcs :: GenAcc -> IO [(FilePath, String)]
mkSrcs (GenAcc m) = mapM mkSrc (M.toList m) where
    mkSrc :: (NS, DList TH.DecsQ) -> IO (FilePath, String)
    mkSrc (ns, qs) = do
        decs <- mapM TH.runQ $ DList.toList qs
        let BT.Text modname = moduleName ns
            modfile = moduleFile ns
            contents = unlines $ map TH.pprint $ decs
        return ( modfile
               , "module " ++ toString modname ++ " where\n" ++
                 "\n" ++
                 "import qualified Data.CapNProto.Untyped\n\n" ++
                 contents
               )

main :: IO ()
main = do
    msg <- BS.getContents >>= decode
    case runWriterT $ runCatchT $ genReq msg of
        Identity (Right (), decls) -> mkSrcs decls >>= mapM_ writeOut
  where
    writeOut (path, contents) = do
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path contents
