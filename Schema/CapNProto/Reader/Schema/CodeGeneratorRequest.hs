{-# LANGUAGE ConstraintKinds #-}
module Schema.CapNProto.Reader.Schema.CodeGeneratorRequest where

import Control.Monad.Catch (MonadThrow)
import Control.Monad.Quota (MonadQuota)

import Data.CapNProto.Blob (Blob)
import qualified Schema.CapNProto.Reader.Schema as S
import qualified Data.CapNProto.Untyped as U

type ReadMsg m b = (MonadThrow m, MonadQuota m, Blob m b)

newtype RequestedFile b = RequestedFile (U.Struct b)

nodes :: ReadMsg m b => S.CodeGeneratorRequest b -> m (Maybe (U.ListOf b (S.Node b)))
nodes (S.CodeGeneratorRequest struct) = do
    ptr <- U.ptrSection struct >>= U.index 0
    case ptr of
        Nothing -> return Nothing
        Just ptr' -> U.requireListStruct ptr' >>= return . Just . fmap S.Node
