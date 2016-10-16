-- | Assembles functionality from several modules to perform main business logic.
module Shiva.Execute (
  loadFeedDataByTitle,
  generateResultFromName,
  catchErrorPage,
) where


import Shiva.Feeds
import Shiva.Config
import Shiva.Database
import Shiva.Translation
import Shiva.HTML
import Shiva.Sources (extractDN)
import Shiva.Get (httpGet)

import Data.Bifunctor (first, second)
import Prelude hiding (lookup)
import Data.List (sortBy)
import Data.Map (Map,lookup,fromList)
import Lucid
import Control.Monad.Error.Class (throwError, catchError)
import Control.Monad.State (lift)
import Data.Text (Text,unpack)


readMetadataMap :: Source -> ShivaM (Map String String)
readMetadataMap = fmap fromList . readPairs

subStep :: Map String String -> FeedItem -> ([FeedItem],[FeedItem]) -> ([FeedItem],[FeedItem])
subStep m i = case lookup (svTitle i) m of
  Just eng -> first  (d:) where d = i {enTitle = eng}
  Nothing  -> second (i:)

subMetadata :: Map String String -> [FeedItem] -> ([FeedItem],[FeedItem])
subMetadata m = foldr (subStep m) ([],[])


-- | Take list of feed items without english titles, fill them in by translating the swedish titles
translateTitles :: [FeedItem] -> ShivaM [FeedItem]
translateTitles ds = do
  ps <- translateSet' $ svTitle <$> ds
  return $ zipWith (\d p -> d {enTitle = english p }) ds ps


loadFeedData :: Source -> ShivaM FeedData
loadFeedData src = do
  fd <- lift $ loadFeedPrelim src
  m  <- readMetadataMap src
  let (xs,ys) = subMetadata m (feedItems fd)
  zs <- translateTitles ys
  writeAritcleMetadata src zs
  return $ fd { feedItems = sortBy (flip compare) (xs ++ zs) }

loadFeedDataByTitle :: String -> ShivaM FeedData
loadFeedDataByTitle str = case lookup str codeMap of
  Just src -> loadFeedData src
  Nothing -> throwError "I don't recognize any feed with that title"


catchErrorPage :: ShivaM (Html ()) -> ShivaM (Html ())
catchErrorPage sh = catchError sh $ return . errorPage


-- | Given swedish and english text separated by |, return the corresponding ShivaResult
genResult :: String -> String -> ShivaResult
genResult sv en =
  let svs = divOn '|' sv
      ens = divOn '|' en
      ps  = zipWithDefault SvenskaPair "" svs ens
  in ShivaResult (length svs == length ens) ps

retrieveContent :: String -> IOX Text
retrieveContent url = do
  txt <- httpGet url
  return $ extractDN txt

generateContentResult :: FeedItem -> ShivaM ShivaResult
generateContentResult di = do
  mx <- readContentData (urlFrag di)
  case mx of
    Just (s,e) -> return $ genResult s e
    Nothing    -> do
      art <- lift $ retrieveContent (urlFull di)
      translateSaveBodyText (urlFrag di) (unpack art)

generateResultFromName :: String -> ShivaM ShivaResult
generateResultFromName name = do
  md <- readArticleMetadata name
  case md of
    Just d  -> generateContentResult d
    Nothing -> throwError "Article by that name seems to be missing."


-- | Take an URL fragment (functioning as an identifier) and text, then translate the text and
--   save the result.
translateSaveBodyText :: String -> String -> ShivaM ShivaResult
translateSaveBodyText name sv = do
  let psv = prep sv
  en <- runTrans psv
  writeContentData (name,psv,en)
  return $ genResult psv en
