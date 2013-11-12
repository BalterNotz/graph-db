module TPM.GraphDB.GenerateBoilerplate where

import TPM.GraphDB.Prelude
import qualified TPM.GraphDB.API as API
import Language.Haskell.TH
import qualified TPM.GraphDB.GenerateBoilerplate.MembersRegistry as MembersRegistry; import TPM.GraphDB.GenerateBoilerplate.MembersRegistry (MembersRegistry)
import qualified Data.Char as Char
import qualified Data.Set as Set
import qualified Data.SafeCopy as SafeCopy
import qualified Data.Serialize as Serialize
import qualified TPM.GraphDB.TH.Q as Q
import qualified TPM.GraphDB.TH.Type as Type
import qualified TPM.GraphDB.CIO as CIO; import TPM.GraphDB.CIO (CIO)
import qualified TPM.GraphDB.GenerateBoilerplate.TagInstanceBuilder as TagInstanceBuilder

-- |
-- Scan the current module for all transaction-functions and 
-- generate appropriate \"event\" data-types, 
-- associating them with the provided database tag.
-- 
generateBoilerplate :: Name -> [Name] -> Q [Dec]
generateBoilerplate tagName valueTypeNames = do

  tagType <-
    Q.reifyType tagName >>= 
    return . fromMaybe (error $ "Not a type name: " ++ show tagName)

  valueTypes <- forM valueTypeNames $ \name -> 
    Q.reifyType name >>= return . fromMaybe (error $ "Not a type name: " ++ show name)
  allValueTypes <- do
    unitType <- [t| () |]
    return $ unitType : valueTypes
        
  (addDecs, getDecs) <- newDecsAccumulator
  tib <- liftCIO $ TagInstanceBuilder.new tagType

  (valueMR, edgeMR, eventMR, eventResultMR) <- 
    liftSTM $ (,,,) 
      <$> MembersRegistry.new (nameBase tagName ++ "_MemberValue_")
      <*> MembersRegistry.new (nameBase tagName ++ "_MemberEdge_")
      <*> MembersRegistry.new (nameBase tagName ++ "_MemberEvent_")
      <*> MembersRegistry.new (nameBase tagName ++ "_MemberEventResult_")

  writeType <- [t| API.Write |]
  readType <- [t| API.Read |]

  let
    addValueType t = do
      memberName <- liftSTM $ MembersRegistry.resolve valueMR t
      liftCIO $ TagInstanceBuilder.addMemberValueConstructor tib memberName t
      addDecs =<< generateIsMemberValueOfInstance t tagType memberName
      addDecs =<< generateEqInstance t
      addDecs =<< generateGenericInstance t
      addDecs =<< generateHashableInstance t
      addDecs =<< generateSafeCopyInstance t
    addEdgeType t = do
      memberName <- liftSTM $ MembersRegistry.resolve edgeMR t
      liftCIO $ TagInstanceBuilder.addMemberEdgeConstructor tib memberName t
      addDecs =<< generateIsMemberEdgeOfInstance t tagType memberName
      addDecs =<< generateEqInstance t
      addDecs =<< generateGenericInstance t
      addDecs =<< generateHashableInstance t
      addDecs =<< generateSafeCopyInstance t
    addValueOrEdgeType t = if isEdge t then addEdgeType t else addValueType t
    addTransactionFunction name argTypes evResultType trType = do
      addDecs =<< generateEvent evName argTypes
      addDecs =<< generateEventInstance evType tagType evName name argTypes evResultType (trType == writeType)
      memberEventName <- liftSTM $ MembersRegistry.resolve eventMR evType
      addDecs =<< generateIsMemberEventOfInstance evType tagType memberEventName
      memberEventResultName <- liftSTM $ MembersRegistry.resolve eventResultMR evResultType
      addDecs =<< generateIsMemberEventResultOfInstance evResultType tagType memberEventResultName
      liftCIO $ TagInstanceBuilder.addMemberEventConstructor tib memberEventName evType
      liftCIO $ TagInstanceBuilder.addMemberEventResultConstructor tib memberEventResultName evResultType
      liftCIO $ TagInstanceBuilder.addMemberEventTransactionClause tib memberEventName memberEventResultName
      
      addDecs =<< generateSafeCopyInstance =<< [t| API.MemberEvent $(return tagType) |]
      addDecs =<< generateSafeCopyInstance =<< [t| API.MemberEventResult $(return tagType) |]

      where
        evName = mkName $ case nameBase name of
          x : xs -> Char.toUpper x : xs
          _ -> []
        evType = ConT evName
    in do
      functions <- Q.reifyLocalFunctions
      forM_ functions $ \(functionName, argTypes, resultType) -> do
        case Type.unapply resultType of
          evResultType : _ : trTagType : trType : [] | 
            trType `elem` [writeType, readType] && trTagType == tagType -> do
              addTransactionFunction functionName argTypes evResultType trType
          _ -> return ()

      forM_ allValueTypes addValueType
      reifyEdgeInstances allValueTypes >>= mapM_ addEdgeType 

  addDecs =<< return . (:[]) =<< liftCIO (TagInstanceBuilder.getDec tib)
  getDecs

  where
    newDecsAccumulator = do
      decsVar <- liftSTM $ newTVar []
      return (addDecs decsVar, getDecs decsVar)
      where
        addDecs decsVar decs = liftSTM $ modifyTVar decsVar (decs ++)
        getDecs decsVar = liftSTM $ readTVar decsVar
    liftSTM = runIO . atomically
    liftCIO = runIO . CIO.run'
    liftIO = runIO

-- reifyLocalTransactionFunctions :: Type -> Q [(Name, [Type], Type)]
-- reifyLocalTransactionFunctions tagType = 

-- |
-- Get a list of all instances of 'Edge' between all possible combinations of provided types.
reifyEdgeInstances :: [Type] -> Q [Type]
reifyEdgeInstances types = do
  ConT familyName <- [t| API.Edge |]
  decs <- fmap join $ sequence $ do
    fromType <- types
    toType <- types
    return $ reifyInstances familyName [fromType, toType]
  return $ catMaybes $ map Type.fromDataInstanceDec decs

isEdge :: Type -> Bool
isEdge t = case Type.unapply t of
  _ : _ : t : [] | t == edgeT -> True
  _ -> False
  where
    edgeT = Q.purify [t| API.Edge |]

generateEvent :: Name -> [Type] -> Q [Dec]
generateEvent adtName argTypes = return [declaration]
  where
    declaration = DataD [] adtName [] [constructor] []
      where
        constructor = NormalC adtName $ map ((IsStrict,)) argTypes

generateEventInstance :: Type -> Type -> Name -> Name -> [Type] -> Type -> Bool -> Q [Dec]
generateEventInstance eventType tagType eventCons functionName argTypes resultType isWrite = 
  [d|
    instance API.Event $(return eventType) $(return tagType) where
      type EventResult $(return eventType) $(return tagType) = $(return resultType)
      eventTransaction = $eventTransactionLambdaQ
  |]
  where
    eventTransactionLambdaQ = lam1E pattern body
      where
        pattern = conP eventCons $ map varP argList
        body = appE constructor $ foldl appE (varE functionName) $ map varE argList
          where
            constructor = if isWrite then [e|API.Write|] else [e|API.Read|]
        argList = zipWith (\i _ -> mkName $ "_" ++ show i) [0..] argTypes

generateIsMemberEventOfInstance :: Type -> Type -> Name -> Q [Dec]
generateIsMemberEventOfInstance eventType tagType memberEventCons = 
  [d|
    instance API.IsMemberEventOf $(return eventType) $(return tagType) where
      toMemberEvent = $(conE memberEventCons)
      fromMemberEvent = $fromMemberEventLambdaQ
  |]
  where
    -- FIXME: Should be a case with a Nothing result possible
    fromMemberEventLambdaQ = Q.caseLambda [pure match1, pure match2]
      where
        match1 = Match pattern body []
          where
            pattern = ConP memberEventCons [VarP patternVarName]
            patternVarName = mkName "_0"
            body = NormalB $ Q.purify [e| Just $(varE patternVarName) |]
        match2 = Match pattern body []
          where
            pattern = WildP
            body = NormalB $ Q.purify [e| Nothing |]

generateIsMemberEventResultOfInstance :: Type -> Type -> Name -> Q [Dec]
generateIsMemberEventResultOfInstance eventResultType tagType memberEventResultName =  
  [d|
    instance API.IsMemberEventResultOf $(return eventResultType) $(return tagType) where
      toMemberEventResult = $(conE memberEventResultName)
      fromMemberEventResult = $(fromMemberEventResultLambdaQ)
  |]
  where
    fromMemberEventResultLambdaQ = Q.caseLambda [pure match1, pure match2]
      where
        match1 = Match pattern body []
          where
            pattern = ConP memberEventResultName [VarP patternVarName]
            patternVarName = mkName "_0"
            body = NormalB $ Q.purify [e| Just $(varE patternVarName) |]
        match2 = Match pattern body []
          where
            pattern = WildP
            body = NormalB $ Q.purify [e| Nothing |]


generateEqInstance :: Type -> Q [Dec]
generateEqInstance t = [d|deriving instance Eq $(return t)|]

generateShowInstance :: Type -> Q [Dec]
generateShowInstance t = [d|deriving instance Show $(return t)|]

generateGenericInstance :: Type -> Q [Dec]
generateGenericInstance t = [d|deriving instance Generic $(return t)|]

generateHashableInstance :: Type -> Q [Dec]
generateHashableInstance t = [d|instance Hashable $(return t)|]

generateSafeCopyInstance :: Type -> Q [Dec]
generateSafeCopyInstance t = case t of
  ConT name -> SafeCopy.deriveSafeCopy 0 'SafeCopy.base name
  _ -> 
    [d|
      instance Serialize.Serialize $(return t)
      instance SafeCopy.SafeCopy $(return t)
    |]

generateSerializeInstance :: Type -> Q [Dec]
generateSerializeInstance t = [d|instance Serialize.Serialize $(return t)|]

generateIsMemberEdgeOfInstance :: Type -> Type -> Name -> Q [Dec]
generateIsMemberEdgeOfInstance edgeType tagType memberEdgeCons = 
  [d|
    instance API.IsMemberEdgeOf $(return edgeType) $(return tagType) where
      toMemberEdge = $(conE memberEdgeCons)
      fromMemberEdge = $fromMemberEdgeLambdaQ
  |]
  where
    fromMemberEdgeLambdaQ = Q.caseLambda [pure match1, pure match2]
      where
        match1 = Match pattern body []
          where
            pattern = ConP memberEdgeCons [VarP patternVarName]
            patternVarName = mkName "_0"
            body = NormalB $ Q.purify [e| Just $(varE patternVarName) |]
        match2 = Match pattern body []
          where
            pattern = WildP
            body = NormalB $ Q.purify [e| Nothing |]

generateIsMemberValueOfInstance :: Type -> Type -> Name -> Q [Dec]
generateIsMemberValueOfInstance valueType tagType memberValueCons = 
  [d|
    instance API.IsMemberValueOf $(return valueType) $(return tagType) where
      toMemberValue = $(conE memberValueCons)
      fromMemberValue = $fromMemberValueLambdaQ
  |]
  where
    fromMemberValueLambdaQ = Q.caseLambda [pure match1, pure match2]
      where
        match1 = Match pattern body []
          where
            pattern = ConP memberValueCons [VarP patternVarName]
            patternVarName = mkName "_0"
            body = NormalB $ Q.purify [e| Just $(varE patternVarName) |]
        match2 = Match pattern body []
          where
            pattern = WildP
            body = NormalB $ Q.purify [e| Nothing |]



