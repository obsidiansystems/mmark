-- |
-- Module      :  Text.MMark.Render
-- Copyright   :  © 2017 Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- MMark rendering machinery.

{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Text.MMark.Render
  ( render )
where

import Control.Arrow
import Control.Monad
import Data.Char (isSpace)
import Data.Monoid hiding ((<>))
import Data.Semigroup
import Lucid
import Text.MMark.Type
import Text.MMark.Util
import qualified Data.Text as T
import qualified Text.URI  as URI

-- | Render a 'MMark' markdown document. You can then render @'Html' ()@ to
-- various things:
--
--     * to lazy 'Data.Taxt.Lazy.Text' with 'renderText'
--     * to lazy 'Data.ByteString.Lazy.ByteString' with 'renderBS'
--     * directly to file with 'renderToFile'

render :: MMark -> Html ()
render MMark {..} =
  mapM_ rBlock mmarkBlocks
  where
    Extension {..} = mmarkExtension
    rBlock
      = applyBlockRender extBlockRender
      . fmap rInlines
      . appEndo extBlockTrans
    rInlines
      = (mkOisInternal &&& mapM_ (applyInlineRender extInlineRender))
      . fmap (appEndo extInlineTrans)

-- | Apply a 'Render' to a given @'Block' 'Html' ()@.

applyBlockRender
  :: Render (Block (Ois, Html ()))
  -> Block (Ois, Html ())
  -> Html ()
applyBlockRender r = getRender r defaultBlockRender

-- | The default 'Block' render. Note that it does not care about what we
-- have rendered so far because it always starts rendering. Thus it's OK to
-- just pass it something dummy as the second argument of the inner
-- function.

defaultBlockRender :: Block (Ois, Html ()) -> Html ()
defaultBlockRender = \case
  ThematicBreak ->
    hr_ [] >> newline
  Heading1 (h,html) ->
    h1_ (mkId h) html >> newline
  Heading2 (h,html) ->
    h2_ (mkId h) html >> newline
  Heading3 (h,html) ->
    h3_ (mkId h) html >> newline
  Heading4 (h,html) ->
    h4_ (mkId h) html >> newline
  Heading5 (h,html) ->
    h5_ (mkId h) html >> newline
  Heading6 (h,html) ->
    h6_ (mkId h) html >> newline
  CodeBlock infoString txt -> do
    let f x = class_ $ "language-" <> T.takeWhile (not . isSpace) x
    pre_ $ code_ (maybe [] (pure . f) infoString) (toHtml txt)
    newline
  Paragraph (_,html) ->
    p_ html >> newline
  Blockquote blocks -> do
    blockquote_ (newline <* mapM_ defaultBlockRender blocks)
    newline
  OrderedList i items -> do
    let startIndex = [start_ (T.pack $ show i) | i /= 1]
    ol_ startIndex $ do
      newline
      forM_ items $ \x -> do
        li_ (newline <* mapM_ defaultBlockRender x)
        newline
    newline
  UnorderedList items -> do
    ul_ $ do
      newline
      forM_ items $ \x -> do
        li_ (newline <* mapM_ defaultBlockRender x)
        newline
    newline
  Naked (_,html) ->
    html >> newline
  where
    mkId ois = [(id_ . headerId . getOis) ois]

-- | Apply a render to a given 'Inline'.

applyInlineRender :: Render Inline -> Inline -> Html ()
applyInlineRender r = getRender r defaultInlineRender

-- | The default render for 'Inline' elements. Comments about
-- 'defaultBlockRender' apply here just as well.

defaultInlineRender :: Inline -> Html ()
defaultInlineRender = \case
  Plain txt ->
    toHtml txt
  LineBreak ->
    br_ [] >> newline
  Emphasis inner ->
    em_ (mapM_ defaultInlineRender inner)
  Strong inner ->
    strong_ (mapM_ defaultInlineRender inner)
  Strikeout inner ->
    del_ (mapM_ defaultInlineRender inner)
  Subscript inner ->
    sub_ (mapM_ defaultInlineRender inner)
  Superscript inner ->
    sup_ (mapM_ defaultInlineRender inner)
  CodeSpan txt ->
    code_ (toHtmlRaw txt)
  Link inner dest mtitle ->
    let title = maybe [] (pure . title_) mtitle
    in a_ (href_ (URI.render dest) : title) (mapM_ defaultInlineRender inner)
  Image desc src mtitle ->
    let title = maybe [] (pure . title_) mtitle
    in img_ (alt_ (asPlainText desc) : src_ (URI.render src) : title)

-- | HTML containing a newline.

newline :: Html ()
newline = "\n"