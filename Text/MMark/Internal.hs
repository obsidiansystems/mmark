-- |
-- Module      :  Text.MMark.Internal
-- Copyright   :  © 2017 Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- Internal definitions you really shouldn't import. Import "Text.MMark"
-- instead.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE RecordWildCards    #-}

module Text.MMark.Internal
  ( MMark (..)
  , Extension (..)
  , Scanner (..)
  , runScanner
  , useExtension
  , useExtensions
  , renderMMark
  , Block (..)
  , Inline (..)
  , Render (..)
  , defaultBlockRender
  , defaultInlineRender )
where

import Control.DeepSeq
import Control.Monad
import Data.Aeson
import Data.Data (Data)
import Data.Function (on)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Monoid hiding ((<>))
import Data.Semigroup
import Data.Text (Text)
import Data.Typeable (Typeable)
import GHC.Generics
import Lucid

-- | Representation of complete markdown document. You can't look inside of
-- 'MMark' on purpose. The only way to influence an 'MMark' document you
-- obtain as a result of parsing is via the extension mechanism.

data MMark = MMark
  { mmarkYaml_ :: Maybe Value
    -- ^ Parsed YAML document at the beginning (optional)
  , mmarkBlocks :: [Block (NonEmpty Inline)]
    -- ^ Actual contents of the document
  , mmarkExtension :: Extension
    -- ^ Extension specifying how to process and render the blocks
  }

-- | An extension. You can apply extensions with 'useExtension' and
-- 'useExtensions' functions. The "Text.MMark.Extension" provides tools for
-- extension creation.
--
-- Note that 'Extension' is an instance of 'Semigroup' and 'Monoid', i.e.
-- you can combine several extensions into one.

data Extension = Extension
  { extBlockTrans   :: forall a. Endo (Block a)
  , extBlockRender  :: Render (Block (Html ()))
  , extInlineTrans  :: Endo Inline
  , extInlineRender :: Render Inline
  }

instance Semigroup Extension where
  x <> y = Extension
    { extBlockTrans   = on (<>) extBlockTrans   x y
    , extBlockRender  = on (<>) extBlockRender  x y
    , extInlineTrans  = on (<>) extInlineTrans  x y
    , extInlineRender = on (<>) extInlineRender x y }

instance Monoid Extension where
  mempty = Extension
    { extBlockTrans   = mempty
    , extBlockRender  = mempty
    , extInlineTrans  = mempty
    , extInlineRender = mempty }
  mappend = (<>)

-- | Apply an 'Extension' to an 'MMark' document. The order in which you
-- apply 'Extension's /does matter/. Extensions you apply first take effect
-- first. In many cases it doesn't matter, but sometimes the difference is
-- important.

useExtension :: Extension -> MMark -> MMark
useExtension ext mmark =
  mmark { mmarkExtension = mmarkExtension mmark <> ext }

-- | Apply several 'Extension's to an 'MMark' document.
--
-- This is a simple shortcut:
--
-- > useExtensions exts = useExtension (mconcat exts)
--
-- As mentioned in the docs for 'useExtension', the order in which you apply
-- extensions matters. Extensions from the list are applied in the order
-- they appear in the list.

useExtensions :: [Extension] -> MMark -> MMark
useExtensions exts = useExtension (mconcat exts)

-- | A scanner. Scanner is something that can extract information from an
-- 'MMark' document.

data Scanner a = Scanner (a -> Block (NonEmpty Inline) -> a)

-- TODO Hell, Scanner is not going to be composable as applicative. We need
-- to come up with something else.

-- | Run a 'Scanner' on an 'MMark'. It's desirable to run it only once
-- because running a scanner is typically an expensive traversal. Exploit
-- the fact that 'Scanner' is an 'Applicative' and combine all scanners you
-- need to run into one, then run that.

runScanner :: MMark -> Scanner a -> a
runScanner = undefined -- TODO

-- | Render a 'MMark' markdown document. You can then render @'Html' ()@ to
-- various things:
--
--     * to lazy 'Data.Taxt.Lazy.Text' with 'renderText'
--     * to lazy 'Data.ByteString.Lazy.ByteString' with 'renderBS'
--     * directly to file with 'renderToFile'

renderMMark :: MMark -> Html ()
renderMMark MMark {..} =
  -- NOTE Here we have the potential for parallel processing, although we
  -- need NFData for Html () for this to work.
  mapM_ produceBlock mmarkBlocks
  where
    Extension {..} = mmarkExtension
    produceBlock   = renderBlock extBlockRender
      . appEndo extBlockTrans
      . fmap (renderInlines extInlineRender . fmap (appEndo extInlineTrans))

-- | We can think of a markdown document as a collection of
-- blocks—structural elements like paragraphs, block quotations, lists,
-- headings, rules, and code blocks. Some blocks (like block quotes and list
-- items) contain other blocks; others (like headings and paragraphs)
-- contain inline content, see 'Inline'.
--
-- We can divide blocks into two types: container blocks, which can contain
-- other blocks, and leaf blocks, which cannot.

data Block a
  = ThematicBreak
    -- ^ Thematic break, leaf block
  | Heading1 a
    -- ^ Heading (level 1), leaf block
  | Heading2 a
    -- ^ Heading (level 2), leaf block
  | Heading3 a
    -- ^ Heading (level 3), leaf block
  | Heading4 a
    -- ^ Heading (level 4), leaf block
  | Heading5 a
    -- ^ Heading (level 5), leaf block
  | Heading6 a
    -- ^ Heading (level 6), leaf block
  | CodeBlock (Maybe Text) Text
    -- ^ Code block, leaf block with info string and contents
  | HtmlBlock Text
    -- ^ HTML block, leaf block
  | Paragraph a
    -- ^ Paragraph, leaf block
  | Blockquote [Block a]
    -- ^ Blockquote container block
  | OrderedList (NonEmpty (Block a))
    -- ^ Ordered list, container block
  | UnorderedList (NonEmpty (Block a))
    -- ^ Unordered list, container block
  deriving (Show, Eq, Ord, Data, Typeable, Generic, Functor)

instance NFData a => NFData (Block a)

-- | Inline markdown content.

data Inline
  = Plain Text
    -- ^ Plain text
  | CodeSpan Text
    -- ^ Code span
  | Link Text Text (Maybe Text)
    -- ^ Link with text, destination, and optionally title
  | Image Text Text (Maybe Text)
    -- ^ Image with description, URL, and optionally title
  | HtmlInline Text
    -- ^ Inline HTML
  deriving (Show, Eq, Ord, Data, Typeable, Generic)

instance NFData Inline

----------------------------------------------------------------------------
-- Renders

-- | An internal type that captures the extensible rendering process we use.
-- The first argument @a@ of the inner function is the thing to render. The
-- second argument is that thing @a@ already rendered (i.e. default
-- rendering of @a@ or result of rendering so far, but actually these things
-- are the same). This may seem a bit weird, but it works really well.

newtype Render a = Render (a -> Html () -> Html ())

instance Semigroup (Render a) where
  Render f <> Render g = Render $ \elt html ->
    g elt (f elt html)

instance Monoid (Render a) where
  mempty  = Render (const id)
  mappend = (<>)

-- | The default 'Block' render. Note that it does not care about what we
-- have rendered so far because it always starts rendering. Thus it's OK to
-- just pass it something dummy as the second argument of the inner
-- function.

defaultBlockRender :: Render (Block (Html ()))
defaultBlockRender = Render $ \block _ ->
  case block of
    ThematicBreak ->
      br_ []
    Heading1 html ->
      h1_ html
    Heading2 html ->
      h2_ html
    Heading3 html ->
      h3_ html
    Heading4 html ->
      h4_ html
    Heading5 html ->
      h5_ html
    Heading6 html ->
      h6_ html
    CodeBlock _ txt ->
      (pre_ . code_ . toHtmlRaw) txt
    HtmlBlock txt ->
      toHtmlRaw txt
    Paragraph html ->
      p_ html
    Blockquote blocks ->
      blockquote_ (mapM_ renderSubBlock blocks)
    OrderedList items ->
      ol_ $ forM_ items (li_ . renderSubBlock)
    UnorderedList items ->
      ul_ $ forM_ items (li_ . renderSubBlock)
  where
    renderSubBlock x =
      let (Render f) = defaultBlockRender in f x (return ())

-- | Apply a render to a given 'Block'.

renderBlock :: Render (Block (Html ())) -> Block (Html ()) -> Html ()
renderBlock (Render f) x = f x (g x (return ()))
  where
    Render g = defaultBlockRender

-- | The default render for 'Inline' elements. Comments about
-- 'defaultBlockRender' apply here just as well.

defaultInlineRender :: Render Inline
defaultInlineRender = Render $ \inline _ ->
  case inline of
    Plain txt ->
      toHtml txt
    CodeSpan txt ->
      code_ (toHtmlRaw txt)
    Link txt dest mtitle ->
      let title = maybe [] (pure . title_) mtitle
      in a_ (href_ dest : title) (toHtml txt)
    Image alt src mtitle ->
      let title = maybe [] (pure . title_) mtitle
      in img_ (alt_ alt : src_ src : title)
    HtmlInline txt ->
      toHtmlRaw txt

-- | Apply a render to a given 'Inline'.

renderInlines :: Render Inline -> NonEmpty Inline -> Html ()
renderInlines (Render f) = mapM_ $ \x -> f x (g x (return ()))
  where
    Render g = defaultInlineRender
