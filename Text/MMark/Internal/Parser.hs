-- |
-- Module      :  Text.MMark.Parser
-- Copyright   :  © 2017–present Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- MMark markdown parser.

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE TypeFamilies              #-}

module Text.MMark.Internal.Parser
  ( MMarkErr (..)
  , parse )
where

import Control.Applicative (Alternative, liftA2)
import Control.Monad
import Data.Bifunctor (Bifunctor (..))
import Data.Bool (bool)
import Data.HTML.Entities (htmlEntityMap)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import Data.Maybe (isNothing, fromJust, catMaybes, isJust)
import Data.Monoid (Any (..))
import Data.Ratio ((%))
import Data.Text (Text)
import Lens.Micro ((^.))
import Text.MMark.Internal.Parser.Internal
import Text.MMark.Internal.Type
import Text.MMark.Internal.Util
import Text.Megaparsec hiding (parse, State (..))
import Text.Megaparsec.Char hiding (eol)
import Text.URI (URI)
import Text.URI.Lens (uriPath)
import qualified Control.Monad.Combinators.NonEmpty as NE
import qualified Data.Aeson                 as Aeson
import qualified Data.Char                  as Char
import qualified Data.DList                 as DList
import qualified Data.HashMap.Strict        as HM
import qualified Data.List.NonEmpty         as NE
import qualified Data.Set                   as E
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Text.Email.Validate        as Email
import qualified Text.Megaparsec.Char.Lexer as L
import qualified Text.URI                   as URI

#if !MIN_VERSION_base(4,13,0)
import Data.Semigroup (Semigroup (..))
#endif

#if !defined(ghcjs_HOST_OS)
import qualified Data.Yaml                  as Yaml
#endif

----------------------------------------------------------------------------
-- Auxiliary data types

-- | Frame that describes where we are in parsing inlines.

data InlineFrame
  = EmphasisFrame      -- ^ Emphasis with asterisk @*@
  | EmphasisFrame_     -- ^ Emphasis with underscore @_@
  | StrongFrame        -- ^ Strong emphasis with asterisk @**@
  | StrongFrame_       -- ^ Strong emphasis with underscore @__@
  | StrikeoutFrame     -- ^ Strikeout
  | SubscriptFrame     -- ^ Subscript
  | SuperscriptFrame   -- ^ Superscript
  deriving (Eq, Ord, Show)

-- | State of inline parsing that specifies whether we expect to close one
-- frame or there is a possibility to close one of two alternatives.

data InlineState
  = SingleFrame InlineFrame             -- ^ One frame to be closed
  | DoubleFrame InlineFrame InlineFrame -- ^ Two frames to be closed
  deriving (Eq, Ord, Show)

----------------------------------------------------------------------------
-- Top-level API

-- | Parse a markdown document in the form of a strict 'Text' value and
-- either report parse errors or return an 'MMark' document.

parse
  :: FilePath
     -- ^ File name (only to be used in error messages), may be empty
  -> Text
     -- ^ Input to parse
  -> Either (ParseErrorBundle Text MMarkErr) MMark
     -- ^ Parse errors or parsed document
parse file input =
  case runBParser pMMark file input of
    Left bundle -> Left bundle
    Right ((myaml, rawBlocks), defs) ->
      let parsed = doInline <$> rawBlocks
          doInline = fmap
            $ first (replaceEof "end of inline block")
            . runIParser defs pInlinesTop
          e2p = either DList.singleton (const DList.empty)
      in case NE.nonEmpty . DList.toList $ foldMap (foldMap e2p) parsed of
           Nothing -> Right MMark
             { mmarkYaml      = myaml
             , mmarkBlocks    = fmap fromRight <$> parsed
             , mmarkExtension = mempty }
           Just errs -> Left ParseErrorBundle
             { bundleErrors = errs
             , bundlePosState = PosState
               { pstateInput = input
               , pstateOffset = 0
               , pstateSourcePos = initialPos file
               , pstateTabWidth = mkPos 4
               , pstateLinePrefix = ""
               }
             }

----------------------------------------------------------------------------
-- Block parser

-- | Parse an MMark document on block level.

pMMark :: BParser (Maybe Aeson.Value, [Block Isp])
pMMark = do
  meyaml <- optional pYamlBlock
  blocks <- pBlocks
  eof
  return $ case meyaml of
    Nothing ->
      (Nothing, blocks)
    Just (Left (o, err)) ->
      (Nothing, prependErr o (YamlParseError err) blocks)
    Just (Right yaml) ->
      (Just yaml, blocks)

-- | Parse a YAML block. On success return the actual parsed 'Aeson.Value' in
-- 'Right', otherwise return 'SourcePos' of parse error and 'String'
-- describing the error as generated by the @yaml@ package in 'Left'.

pYamlBlock :: BParser (Either (Int, String) Aeson.Value)
pYamlBlock = do
  string "---" *> sc' *> eol
  let go acc = do
        l <- takeWhileP Nothing notNewline
        void (optional eol)
        e <- atEnd
        if e || T.stripEnd l == "---"
          then return acc
          else go (acc . (l:))
  doffset <- getOffset
  ls <- go id <*> ([] <$ sc)
  return $ decodeYaml ls doffset

-- | Parse several (possibly zero) blocks in a row.

pBlocks :: BParser [Block Isp]
pBlocks = catMaybes <$> many pBlock

-- | Parse a single block of markdown document.

pBlock :: BParser (Maybe (Block Isp))
pBlock = do
  sc
  rlevel <- refLevel
  alevel <- L.indentLevel
  done   <- atEnd
  if done || alevel < rlevel then empty else
    case compare alevel (ilevel rlevel) of
      LT -> choice
        [ Just <$> pThematicBreak
        , Just <$> pAtxHeading
        , Just <$> pFencedCodeBlock
        , Just <$> pTable
        , Just <$> pUnorderedList
        , Just <$> pOrderedList
        , Just <$> pBlockquote
        , pReferenceDef
        , Just <$> pParagraph ]
      _  ->
          Just <$> pIndentedCodeBlock

-- | Parse a thematic break.

pThematicBreak :: BParser (Block Isp)
pThematicBreak = do
  l' <- lookAhead nonEmptyLine
  let l = T.filter (not . isSpace) l'
  if T.length l >= 3   &&
     (T.all (== '*') l ||
      T.all (== '-') l ||
      T.all (== '_') l)
    then ThematicBreak <$ nonEmptyLine <* sc
    else empty

-- | Parse an ATX heading.

pAtxHeading :: BParser (Block Isp)
pAtxHeading = do
  (void . lookAhead . try) hashIntro
  withRecovery recover $ do
    hlevel <- length <$> hashIntro
    sc1'
    ispOffset <- getOffset
    r <- someTill (satisfy notNewline <?> "heading character") . try $
      optional (sc1' *> some (char '#') *> sc') *> (eof <|> eol)
    let toBlock = case hlevel of
          1 -> Heading1
          2 -> Heading2
          3 -> Heading3
          4 -> Heading4
          5 -> Heading5
          _ -> Heading6
    toBlock (IspSpan ispOffset (T.strip (T.pack r))) <$ sc
  where
    hashIntro = count' 1 6 (char '#')
    recover err =
      Heading1 (IspError err) <$ takeWhileP Nothing notNewline <* sc

-- | Parse a fenced code block.

pFencedCodeBlock :: BParser (Block Isp)
pFencedCodeBlock = do
  alevel <- L.indentLevel
  (ch, n, infoString) <- pOpeningFence
  let content = label "code block content" (option "" nonEmptyLine <* eol)
  ls <- manyTill content (pClosingFence ch n)
  CodeBlock infoString (assembleCodeBlock alevel ls) <$ sc

-- | Parse the opening fence of a fenced code block.

pOpeningFence :: BParser (Char, Int, Maybe Text)
pOpeningFence = p '`' <|> p '~'
  where
    p ch = try $ do
      void $ count 3 (char ch)
      n  <- (+ 3) . length <$> many (char ch)
      ml <- optional
        (T.strip <$> someEscapedWith notNewline <?> "info string")
      guard (maybe True (not . T.any (== '`')) ml)
      (ch, n,
         case ml of
           Nothing -> Nothing
           Just l  ->
             if T.null l
               then Nothing
               else Just l) <$ eol

-- | Parse the closing fence of a fenced code block.

pClosingFence :: Char -> Int -> BParser ()
pClosingFence ch n =  try . label "closing code fence" $ do
  clevel <- ilevel <$> refLevel
  void $ L.indentGuard sc' LT clevel
  void $ count n (char ch)
  (void . many . char) ch
  sc'
  eof <|> eol

-- | Parse an indented code block.

pIndentedCodeBlock :: BParser (Block Isp)
pIndentedCodeBlock = do
  alevel <- L.indentLevel
  clevel <- ilevel <$> refLevel
  let go ls = do
        indented <- lookAhead $
          (>= clevel) <$> (sc *> L.indentLevel)
        if indented
          then do
            l        <- option "" nonEmptyLine
            continue <- eol'
            let ls' = ls . (l:)
            if continue
              then go ls'
              else return ls'
          else return ls
      -- NOTE This is a bit unfortunate, but it's difficult to guarantee
      -- that preceding space is not yet consumed when we get to
      -- interpreting input as an indented code block, so we need to restore
      -- the space this way.
      f x      = T.replicate (unPos alevel - 1) " " <> x
      g []     = []
      g (x:xs) = f x : xs
  ls <- g . ($ []) <$> go id
  CodeBlock Nothing (assembleCodeBlock clevel ls) <$ sc

-- | Parse an unorederd list.

pUnorderedList :: BParser (Block Isp)
pUnorderedList = do
  (bullet, bulletPos, minLevel, indLevel) <-
    pListBullet Nothing
  x  <- innerBlocks bulletPos minLevel indLevel
  xs <- many $ do
    (_, bulletPos', minLevel', indLevel') <-
      pListBullet (Just (bullet, bulletPos))
    innerBlocks bulletPos' minLevel' indLevel'
  return (UnorderedList (normalizeListItems (x:|xs)))
  where
    innerBlocks bulletPos minLevel indLevel = do
      p <- getSourcePos
      let tooFar = sourceLine p > sourceLine bulletPos <> pos1
          rlevel = slevel minLevel indLevel
      if tooFar || sourceColumn p < minLevel
        then return [bool Naked Paragraph tooFar emptyIspSpan]
        else subEnv True rlevel pBlocks

-- | Parse a list bullet. Return a tuple with the following components (in
-- order):
--
--     * 'Char' used to represent the bullet
--     * 'SourcePos' at which the bullet was located
--     * the closest column position where content could start
--     * the indentation level after the bullet

pListBullet
  :: Maybe (Char, SourcePos)
     -- ^ Bullet 'Char' and start position of the first bullet in a list
  -> BParser (Char, SourcePos, Pos, Pos)
pListBullet mbullet = try $ do
  pos    <- getSourcePos
  l      <- (<> mkPos 2) <$> L.indentLevel
  bullet <-
    case mbullet of
      Nothing -> char '-' <|> char '+' <|> char '*'
      Just (bullet, bulletPos) -> do
        guard (sourceColumn pos >= sourceColumn bulletPos)
        char bullet
  eof <|> sc1
  l'     <- L.indentLevel
  return (bullet, pos, l, l')

-- | Parse an ordered list.

pOrderedList :: BParser (Block Isp)
pOrderedList = do
  startOffset <- getOffset
  (startIx, del, startPos, minLevel, indLevel) <-
    pListIndex Nothing
  x  <- innerBlocks startPos minLevel indLevel
  xs <- manyIndexed (startIx + 1) $ \expectedIx -> do
    startOffset' <- getOffset
    (actualIx, _, startPos', minLevel', indLevel') <-
      pListIndex (Just (del, startPos))
    let f blocks =
          if actualIx == expectedIx
            then blocks
            else prependErr
                   startOffset'
                   (ListIndexOutOfOrder actualIx expectedIx)
                   blocks
    f <$> innerBlocks startPos' minLevel' indLevel'
  return . OrderedList startIx . normalizeListItems $
    (if startIx <= 999999999
       then x
       else prependErr startOffset (ListStartIndexTooBig startIx) x)
    :| xs
  where
    innerBlocks indexPos minLevel indLevel = do
      p <- getSourcePos
      let tooFar = sourceLine p > sourceLine indexPos <> pos1
          rlevel = slevel minLevel indLevel
      if tooFar || sourceColumn p < minLevel
        then return [bool Naked Paragraph tooFar emptyIspSpan]
        else subEnv True rlevel pBlocks

-- | Parse a list index. Return a tuple with the following components (in
-- order):
--
--     * 'Word' parsed numeric index
--     * 'Char' used as delimiter after the numeric index
--     * 'SourcePos' at which the index was located
--     * the closest column position where content could start
--     * the indentation level after the index

pListIndex
  :: Maybe (Char, SourcePos)
     -- ^ Delimiter 'Char' and start position of the first index in a list
  -> BParser (Word, Char, SourcePos, Pos, Pos)
pListIndex mstart = try $ do
  pos <- getSourcePos
  i   <- L.decimal
  del <- case mstart of
    Nothing -> char '.' <|> char ')'
    Just (del, startPos) -> do
      guard (sourceColumn pos >= sourceColumn startPos)
      char del
  l   <- (<> pos1) <$> L.indentLevel
  eof <|> sc1
  l'  <- L.indentLevel
  return (i, del, pos, l, l')

-- | Parse a block quote.

pBlockquote :: BParser (Block Isp)
pBlockquote = do
  minLevel <- try $ do
    minLevel <- (<> pos1) <$> L.indentLevel
    void (char '>')
    eof <|> sc
    l <- L.indentLevel
    return $
      if l > minLevel
        then minLevel <> pos1
        else minLevel
  indLevel <- L.indentLevel
  if indLevel >= minLevel
    then do
      let rlevel = slevel minLevel indLevel
      xs <- subEnv False rlevel pBlocks
      return (Blockquote xs)
    else return (Blockquote [])

-- | Parse a link\/image reference definition and register it.

pReferenceDef :: BParser (Maybe (Block Isp))
pReferenceDef = do
  (o, dlabel) <- try (pRefLabel <* char ':')
  withRecovery recover $ do
    sc' <* optional eol <* sc'
    uri <- pUri
    hadSpN <- optional $
      (sc1' *> option False (True <$ eol)) <|> (True <$ (sc' <* eol))
    sc'
    mtitle <-
      if isJust hadSpN
        then optional pTitle <* sc'
        else return Nothing
    case (hadSpN, mtitle) of
      (Just True,  Nothing) -> return ()
      _                     -> hidden eof <|> eol
    conflict <- registerReference dlabel (uri, mtitle)
    when conflict $ do
      setOffset o
      customFailure (DuplicateReferenceDefinition dlabel)
    Nothing <$ sc
  where
    recover err =
      Just (Naked (IspError err)) <$ takeWhileP Nothing notNewline <* sc

-- | Parse a pipe table.

pTable :: BParser (Block Isp)
pTable = do
  (n, headerRow) <- try $ do
    pos <- L.indentLevel
    option False (T.any (== '|') <$> lookAhead nonEmptyLine) >>= guard
    let pipe' = option False (True <$ pipe)
    l <- pipe'
    headerRow <- NE.sepBy1 cell (try (pipe <* notFollowedBy eol))
    r <- pipe'
    let n = NE.length headerRow
    guard (n > 1 || l || r)
    eol <* sc'
    L.indentLevel >>= \i -> guard (i == pos || i == (pos <> pos1))
    lookAhead nonEmptyLine >>= guard . isHeaderLike
    return (n, headerRow)
  withRecovery recover $ do
    sc'
    caligns <- rowWrapper (NE.fromList <$> sepByCount n calign pipe)
    otherRows <- many $ do
      endOfTable >>= guard . not
      rowWrapper (NE.fromList <$> sepByCount n cell pipe)
    Table caligns (headerRow :| otherRows) <$ sc
  where
    cell = do
      o <- getOffset
      txt      <- fmap (T.stripEnd . T.pack) . foldMany' . choice $
        [ (++) . T.unpack <$> hidden (string "\\|")
        , (++) . T.unpack <$> pCodeSpanB
        , (:) <$> label "inline content" (satisfy cellChar) ]
      return (IspSpan o txt)
    cellChar x = x /= '|' && notNewline x
    rowWrapper p = do
      void (optional pipe)
      r <- p
      void (optional pipe)
      eof <|> eol
      sc'
      return r
    pipe = char '|' <* sc'
    calign = do
      let colon' = option False (True <$ char ':')
      l <- colon'
      void (count 3 (char '-') <* many (char '-'))
      r <- colon'
      sc'
      return $
        case (l, r) of
          (False, False) -> CellAlignDefault
          (True,  False) -> CellAlignLeft
          (False, True)  -> CellAlignRight
          (True,  True)  -> CellAlignCenter
    isHeaderLike txt =
      T.length (T.filter isHeaderConstituent txt) % T.length txt >
      8 % 10
    isHeaderConstituent x =
      isSpace x || x == '|' || x == '-' || x == ':'
    endOfTable =
      lookAhead (option True (isBlank <$> nonEmptyLine))
    recover err =
      Naked (IspError (replaceEof "end of table block" err)) <$
        manyTill
          (optional nonEmptyLine)
          (endOfTable >>= guard) <* sc

-- | Parse a paragraph or naked text (is some cases).

pParagraph :: BParser (Block Isp)
pParagraph = do
  startOffset <- getOffset
  allowNaked <- isNakedAllowed
  rlevel     <- refLevel
  let go ls = do
        l <- lookAhead (option "" nonEmptyLine)
        broken <- succeeds . lookAhead . try $ do
          sc
          alevel <- L.indentLevel
          guard (alevel < ilevel rlevel)
          unless (alevel < rlevel) . choice $
            [ void (char '>')
            , void pThematicBreak
            , void pAtxHeading
            , void pOpeningFence
            , void (pListBullet Nothing)
            , void (pListIndex  Nothing) ]
        if isBlank l
          then return (ls, Paragraph)
          else if broken
                 then return (ls, Naked)
                 else do
                   void nonEmptyLine
                   continue <- eol'
                   let ls' = ls . (l:)
                   if continue
                     then go ls'
                     else return (ls', Naked)
  l        <- nonEmptyLine
  continue <- eol'
  (ls, toBlock) <-
    if continue
      then go id
      else return (id, Naked)
  (if allowNaked then toBlock else Paragraph)
    (IspSpan startOffset (assembleParagraph (l:ls []))) <$ sc

----------------------------------------------------------------------------
-- Auxiliary block-level parsers

-- | 'match' a code span, this is a specialised and adjusted version of
-- 'pCodeSpan'.

pCodeSpanB :: BParser Text
pCodeSpanB = fmap fst . match . hidden $ do
  n <- try (length <$> some (char '`'))
  let finalizer = try $ do
        void $ count n (char '`')
        notFollowedBy (char '`')
  skipManyTill (label "code span content" $
                  takeWhile1P Nothing (== '`') <|>
                  takeWhile1P Nothing (\x -> x /= '`' && notNewline x))
    finalizer

----------------------------------------------------------------------------
-- Inline parser

-- | The top level inline parser.

pInlinesTop :: IParser (NonEmpty Inline)
pInlinesTop = do
  inlines <- pInlines
  eof <|> void pLfdr
  return inlines

-- | Parse inlines using settings from given 'InlineConfig'.

pInlines :: IParser (NonEmpty Inline)
pInlines = do
  done        <- atEnd
  allowsEmpty <- isEmptyAllowed
  if done
    then
      if allowsEmpty
        then (return . nes . Plain) ""
        else unexpEic EndOfInput
    else NE.some $ do
      mch <- lookAhead (anySingle <?> "inline content")
      case mch of
        '`' -> pCodeSpan
        '[' -> do
          allowsLinks <- isLinksAllowed
          if allowsLinks
            then pLink
            else unexpEic (Tokens $ nes '[')
        '!' -> do
          gotImage <- (succeeds . void . lookAhead . string) "!["
          allowsImages <- isImagesAllowed
          if gotImage
            then if allowsImages
                   then pImage
                   else unexpEic (Tokens . NE.fromList $ "![")
            else pPlain
        '<' -> do
          allowsLinks <- isLinksAllowed
          if allowsLinks
            then try pAutolink <|> pPlain
            else pPlain
        '\\' ->
          try pHardLineBreak <|> pPlain
        ch ->
          if isFrameConstituent ch
            then pEnclosedInline
            else pPlain

-- | Parse a code span.
--
-- See also: 'pCodeSpanB'.

pCodeSpan :: IParser Inline
pCodeSpan = do
  n <- try (length <$> some (char '`'))
  let finalizer = try $ do
        void $ count n (char '`')
        notFollowedBy (char '`')
  r <- CodeSpan . collapseWhiteSpace . T.concat <$>
    manyTill (label "code span content" $
               takeWhile1P Nothing (== '`') <|>
               takeWhile1P Nothing (/= '`'))
      finalizer
  r <$ lastChar OtherChar

-- | Parse a link.

pLink :: IParser Inline
pLink = do
  void (char '[')
  o <- getOffset
  txt <- disallowLinks (disallowEmpty pInlines)
  void (char ']')
  (dest, mtitle) <- pLocation o txt
  Link txt dest mtitle <$ lastChar OtherChar

-- | Parse an image.

pImage :: IParser Inline
pImage = do
  (pos, alt)    <- emptyAlt <|> nonEmptyAlt
  (src, mtitle) <- pLocation pos alt
  Image alt src mtitle <$ lastChar OtherChar
  where
    emptyAlt = do
      o <- getOffset
      void (string "![]")
      return (o + 2, nes (Plain ""))
    nonEmptyAlt = do
      void (string "![")
      o <- getOffset
      alt <- disallowImages (disallowEmpty pInlines)
      void (char ']')
      return (o, alt)

-- | Parse an autolink.

pAutolink :: IParser Inline
pAutolink = between (char '<') (char '>') $ do
  notFollowedBy (char '>')
  uri' <- URI.parser
  let (txt, uri) =
        case isEmailUri uri' of
          Nothing ->
            ( (nes . Plain . URI.render) uri'
            , uri' )
          Just email ->
            ( nes (Plain email)
            , URI.makeAbsolute mailtoScheme uri' )
  Link txt uri Nothing <$ lastChar OtherChar

-- | Parse inline content inside an enclosing construction such as emphasis,
-- strikeout, superscript, and\/or subscript markup.

pEnclosedInline :: IParser Inline
pEnclosedInline = disallowEmpty $ pLfdr >>= \case
  SingleFrame x ->
    liftFrame x <$> pInlines <* pRfdr x
  DoubleFrame x y -> do
    inlines0  <- pInlines
    thisFrame <- pRfdr x <|> pRfdr y
    let thatFrame = if thisFrame == x then y else x
    minlines1 <- optional pInlines
    void (pRfdr thatFrame)
    return . liftFrame thatFrame $
      case minlines1 of
        Nothing ->
          nes (liftFrame thisFrame inlines0)
        Just inlines1 ->
          liftFrame thisFrame inlines0 <| inlines1

-- | Parse a hard line break.

pHardLineBreak :: IParser Inline
pHardLineBreak = do
  void (char '\\')
  eol
  notFollowedBy eof
  sc'
  lastChar SpaceChar
  return LineBreak

-- | Parse plain text.

pPlain :: IParser Inline
pPlain = fmap (Plain . bakeText) . foldSome $ do
  ch <- lookAhead (anySingle <?> "inline content")
  let newline' =
        (('\n':) . dropWhile isSpace) <$ eol <* sc' <* lastChar SpaceChar
  case ch of
    '\\' -> (:) <$>
      ((escapedChar <* lastChar OtherChar) <|>
        try (char '\\' <* notFollowedBy eol <* lastChar OtherChar))
    '\n' ->
      newline'
    '\r' ->
      newline'
    '!' -> do
      notFollowedBy (string "![")
      (:) <$> char '!' <* lastChar PunctChar
    '<' -> do
      notFollowedBy pAutolink
      (:) <$> char '<' <* lastChar PunctChar
    '&' -> choice
      [ (:) <$> numRef
      , (++) . reverse <$> entityRef
      , (:) <$> char '&' ] <* lastChar PunctChar
    _ ->
      (:) <$>
        if Char.isSpace ch
          then char ch <* lastChar SpaceChar
          else if isSpecialChar ch
                 then failure
                   (Just . Tokens . nes $ ch)
                   (E.singleton . Label . NE.fromList $ "inline content")
                 else if Char.isPunctuation ch
                        then char ch <* lastChar PunctChar
                        else char ch <* lastChar OtherChar

----------------------------------------------------------------------------
-- Auxiliary inline-level parsers

-- | Parse an inline and reference-style link\/image location.

pLocation
  :: Int               -- ^ Offset where the content inlines start
  -> NonEmpty Inline   -- ^ The inner content inlines
  -> IParser (URI, Maybe Text) -- ^ URI and optionally title
pLocation innerOffset inner = do
  mr <- optional (inplace <|> withRef)
  case mr of
    Nothing ->
      collapsed innerOffset inner <|> shortcut innerOffset inner
    Just (dest, mtitle) ->
      return (dest, mtitle)
  where
    inplace = do
      void (char '(')
      sc'
      dest     <- pUri
      hadSpace <- option False (True <$ sc1)
      mtitle   <- if hadSpace
        then optional pTitle <* sc'
        else return Nothing
      void (char ')')
      return (dest, mtitle)
    withRef =
      pRefLabel >>= uncurry lookupRef
    collapsed o inlines = do
      -- NOTE We need to do these manipulations so the failure caused by
      -- @'string' "[]"@ does not overwrite our custom failures.
      o' <- getOffset
      setOffset o
      (void . hidden . string) "[]"
      setOffset (o' + 2)
      lookupRef o (mkLabel inlines)
    shortcut o inlines =
      lookupRef o (mkLabel inlines)
    lookupRef o dlabel =
      lookupReference dlabel >>= \case
        Left names -> do
          setOffset o
          customFailure (CouldNotFindReferenceDefinition dlabel names)
        Right x ->
          return x
    mkLabel = T.unwords . T.words . asPlainText

-- | Parse a URI.

pUri :: (Ord e, Show e, MonadParsec e Text m) => m URI
pUri = between (char '<') (char '>') URI.parser <|> naked
  where
    naked = do
      let f x = not (isSpaceN x || x == ')')
          l   = "end of URI"
      (s, s') <- T.span f <$> getInput
      when (T.null s) . void $
        (satisfy f <?> "URI") -- this will now fail
      setInput s
      r <- region (replaceEof l) (URI.parser <* label l eof)
      setInput s'
      return r

-- | Parse a title of a link or an image.

pTitle :: MonadParsec MMarkErr Text m => m Text
pTitle = choice
  [ p '\"' '\"'
  , p '\'' '\''
  , p '('  ')' ]
  where
    p start end = between (char start) (char end) $
      let f x = x /= end
      in manyEscapedWith f "unescaped character"

-- | Parse label of a reference link.

pRefLabel :: MonadParsec MMarkErr Text m => m (Int, Text)
pRefLabel = do
  try $ do
    void (char '[')
    notFollowedBy (char ']')
  o <- getOffset
  sc
  let f x = x /= '[' && x /= ']'
  dlabel <- someEscapedWith f <?> "reference label"
  void (char ']')
  return (o, dlabel)

-- | Parse an opening markup sequence corresponding to given 'InlineState'.

pLfdr :: IParser InlineState
pLfdr = try $ do
  o <- getOffset
  let r st = st <$ string (inlineStateDel st)
  st <- hidden $ choice
    [ r (DoubleFrame StrongFrame StrongFrame)
    , r (DoubleFrame StrongFrame EmphasisFrame)
    , r (SingleFrame StrongFrame)
    , r (SingleFrame EmphasisFrame)
    , r (DoubleFrame StrongFrame_ StrongFrame_)
    , r (DoubleFrame StrongFrame_ EmphasisFrame_)
    , r (SingleFrame StrongFrame_)
    , r (SingleFrame EmphasisFrame_)
    , r (DoubleFrame StrikeoutFrame StrikeoutFrame)
    , r (DoubleFrame StrikeoutFrame SubscriptFrame)
    , r (SingleFrame StrikeoutFrame)
    , r (SingleFrame SubscriptFrame)
    , r (SingleFrame SuperscriptFrame) ]
  let dels = inlineStateDel st
      failNow = do
        setOffset o
        (customFailure . NonFlankingDelimiterRun . toNesTokens) dels
  lch <- getLastChar
  rch <- getNextChar OtherChar
  when (lch >= rch) failNow
  return st

-- | Parse a closing markup sequence corresponding to given 'InlineFrame'.

pRfdr :: InlineFrame -> IParser InlineFrame
pRfdr frame = try $ do
  let dels = inlineFrameDel frame
      expectingInlineContent = region $ \case
        TrivialError pos us es -> TrivialError pos us $
          E.insert (Label $ NE.fromList "inline content") es
        other -> other
  o <- getOffset
  (void . expectingInlineContent . string) dels
  let failNow = do
        setOffset o
        (customFailure . NonFlankingDelimiterRun . toNesTokens) dels
  lch <- getLastChar
  rch <- getNextChar SpaceChar
  when (lch <= rch) failNow
  return frame

-- | Get 'CharType' of the next char in the input stream.

getNextChar
  :: CharType          -- ^ What we should consider frame constituent characters
  -> IParser CharType
getNextChar frameType = lookAhead (option SpaceChar (charType <$> anySingle))
  where
    charType ch
      | isFrameConstituent ch = frameType
      | Char.isSpace       ch = SpaceChar
      | ch == '\\'            = OtherChar
      | Char.isPunctuation ch = PunctChar
      | otherwise             = OtherChar

----------------------------------------------------------------------------
-- Parsing helpers

manyIndexed :: (Alternative m, Num n) => n -> (n -> m a) -> m [a]
manyIndexed n' m = go n'
  where
    go !n = liftA2 (:) (m n) (go (n + 1)) <|> pure []

foldMany :: MonadPlus m => m (a -> a) -> m (a -> a)
foldMany f = go id
  where
    go g =
      optional f >>= \case
        Nothing -> pure g
        Just h  -> go (h . g)

foldMany' :: MonadPlus m => m ([a] -> [a]) -> m [a]
foldMany' f = ($ []) <$> go id
  where
    go g =
      optional f >>= \case
        Nothing -> pure g
        Just h  -> go (g . h)

foldSome :: MonadPlus m => m (a -> a) -> m (a -> a)
foldSome f = liftA2 (flip (.)) f (foldMany f)

foldSome' :: MonadPlus m => m ([a] -> [a]) -> m [a]
foldSome' f = liftA2 ($) f (foldMany' f)

sepByCount :: MonadPlus m => Int -> m a -> m sep -> m [a]
sepByCount 0 _ _   = pure []
sepByCount n p sep = liftA2 (:) p (count (n - 1) (sep *> p))

nonEmptyLine :: BParser Text
nonEmptyLine = takeWhile1P Nothing notNewline

manyEscapedWith :: MonadParsec MMarkErr Text m
  => (Char -> Bool)
  -> String
  -> m Text
manyEscapedWith f l = fmap T.pack . foldMany' . choice $
  [ (:) <$> escapedChar
  , (:) <$> numRef
  , (++) . reverse <$> entityRef
  , (:) <$> satisfy f <?> l ]

someEscapedWith :: MonadParsec MMarkErr Text m
  => (Char -> Bool)
  -> m Text
someEscapedWith f = fmap T.pack . foldSome' . choice $
  [ (:) <$> escapedChar
  , (:) <$> numRef
  , (++) . reverse <$> entityRef
  , (:) <$> satisfy f ]

escapedChar :: MonadParsec e Text m => m Char
escapedChar = label "escaped character" $
  try (char '\\' *> satisfy isAsciiPunctuation)

-- | Parse an HTML5 entity reference.

entityRef :: MonadParsec MMarkErr Text m => m String
entityRef = do
  o  <- getOffset
  let f (TrivialError _ us es) = TrivialError o us es
      f (FancyError   _ xs)    = FancyError   o xs
  name <- try . region f $ between (char '&') (char ';')
    (takeWhile1P Nothing Char.isAlphaNum <?> "HTML5 entity name")
  case HM.lookup name htmlEntityMap of
    Nothing -> do
      setOffset o
      customFailure (UnknownHtmlEntityName name)
    Just txt -> return (T.unpack txt)

-- | Parse a numeric character using the given numeric parser.

numRef :: MonadParsec MMarkErr Text m => m Char
numRef = do
  o <- getOffset
  let f = between (string "&#") (char ';')
  n   <- try (f (char' 'x' *> L.hexadecimal)) <|> f L.decimal
  if n == 0 || n > fromEnum (maxBound :: Char)
    then do
      setOffset o
      customFailure (InvalidNumericCharacter n)
    else return (Char.chr n)

sc :: MonadParsec e Text m => m ()
sc = void $ takeWhileP (Just "white space") isSpaceN

sc1 :: MonadParsec e Text m => m ()
sc1 = void $ takeWhile1P (Just "white space") isSpaceN

sc' :: MonadParsec e Text m => m ()
sc' = void $ takeWhileP (Just "white space") isSpace

sc1' :: MonadParsec e Text m => m ()
sc1' = void $ takeWhile1P (Just "white space") isSpace

eol :: MonadParsec e Text m => m ()
eol = void . label "newline" $ choice
  [ string "\n"
  , string "\r\n"
  , string "\r" ]

eol' :: MonadParsec e Text m => m Bool
eol' = option False (True <$ eol)

----------------------------------------------------------------------------
-- Char classification

isSpace :: Char -> Bool
isSpace x = x == ' ' || x == '\t'

isSpaceN :: Char -> Bool
isSpaceN x = isSpace x || isNewline x

isNewline :: Char -> Bool
isNewline x = x == '\n' || x == '\r'

notNewline :: Char -> Bool
notNewline = not . isNewline

isFrameConstituent :: Char -> Bool
isFrameConstituent = \case
  '*' -> True
  '^' -> True
  '_' -> True
  '~' -> True
  _   -> False

isMarkupChar :: Char -> Bool
isMarkupChar x = isFrameConstituent x || f x
  where
    f = \case
      '[' -> True
      ']' -> True
      '`' -> True
      _   -> False

isSpecialChar :: Char -> Bool
isSpecialChar x = isMarkupChar x || x == '\\' || x == '!' || x == '<'

isAsciiPunctuation :: Char -> Bool
isAsciiPunctuation x =
  (x >= '!' && x <= '/') ||
  (x >= ':' && x <= '@') ||
  (x >= '[' && x <= '`') ||
  (x >= '{' && x <= '~')

----------------------------------------------------------------------------
-- Other helpers

slevel :: Pos -> Pos -> Pos
slevel a l = if l >= ilevel a then a else l

ilevel :: Pos -> Pos
ilevel = (<> mkPos 4)

isBlank :: Text -> Bool
isBlank = T.all isSpace

assembleCodeBlock :: Pos -> [Text] -> Text
assembleCodeBlock indent ls = T.unlines (stripIndent indent <$> ls)

stripIndent :: Pos -> Text -> Text
stripIndent indent txt = T.drop m txt
  where
    m = snd $ T.foldl' f (0, 0) (T.takeWhile isSpace txt)
    f (!j, !n) ch
      | j  >= i    = (j, n)
      | ch == ' '  = (j + 1, n + 1)
      | ch == '\t' = (j + 4, n + 1)
      | otherwise  = (j, n)
    i = unPos indent - 1

assembleParagraph :: [Text] -> Text
assembleParagraph = go
  where
    go []     = ""
    go [x]    = T.dropWhileEnd isSpace x
    go (x:xs) = x <> "\n" <> go xs

collapseWhiteSpace :: Text -> Text
collapseWhiteSpace =
  T.stripEnd . T.filter (/= '\0') . snd . T.mapAccumL f True
  where
    f seenSpace ch =
      case (seenSpace, g ch) of
        (False, False) -> (False, ch)
        (True,  False) -> (False, ch)
        (False, True)  -> (True,  ' ')
        (True,  True)  -> (True,  '\0')
    g ' '  = True
    g '\t' = True
    g '\n' = True
    g _    = False

inlineStateDel :: InlineState -> Text
inlineStateDel = \case
  SingleFrame x   -> inlineFrameDel x
  DoubleFrame x y -> inlineFrameDel x <> inlineFrameDel y

liftFrame :: InlineFrame -> NonEmpty Inline -> Inline
liftFrame = \case
  StrongFrame      -> Strong
  EmphasisFrame    -> Emphasis
  StrongFrame_     -> Strong
  EmphasisFrame_   -> Emphasis
  StrikeoutFrame   -> Strikeout
  SubscriptFrame   -> Subscript
  SuperscriptFrame -> Superscript

inlineFrameDel :: InlineFrame -> Text
inlineFrameDel = \case
  EmphasisFrame    -> "*"
  EmphasisFrame_   -> "_"
  StrongFrame      -> "**"
  StrongFrame_     -> "__"
  StrikeoutFrame   -> "~~"
  SubscriptFrame   -> "~"
  SuperscriptFrame -> "^"

replaceEof :: forall e. Show e => String -> ParseError Text e -> ParseError Text e
replaceEof altLabel = \case
  TrivialError pos us es -> TrivialError pos (f <$> us) (E.map f es)
  FancyError   pos xs    -> FancyError pos xs
  where
    f EndOfInput = Label (NE.fromList altLabel)
    f x          = x

isEmailUri :: URI -> Maybe Text
isEmailUri uri =
  case URI.unRText <$> uri ^. uriPath of
    [x] ->
      if Email.isValid (TE.encodeUtf8 x) &&
          (isNothing (URI.uriScheme uri) ||
           URI.uriScheme uri == Just mailtoScheme)
        then Just x
        else Nothing
    _ -> Nothing

-- | Decode the yaml block to a 'Aeson.Value'. On GHCJs, without access to
-- libyaml we just return an empty object. It's worth using a pure haskell
-- parser later if this is unacceptable for someone's needs.

decodeYaml :: [T.Text] -> Int -> (Either (Int,String) Aeson.Value)
#ifdef ghcjs_HOST_OS
decodeYaml _ _ = pure $ Aeson.object []
#else
decodeYaml ls doffset =
  case (Yaml.decodeEither' . TE.encodeUtf8 . T.intercalate "\n") ls of
    Left err' ->
      let (moffset, err) = splitYamlError err'
      in Left (maybe doffset (+ doffset) moffset, err)
    Right v -> Right v

splitYamlError
  :: Yaml.ParseException
  -> (Maybe Int, String)
splitYamlError = \case
  Yaml.NonScalarKey -> (Nothing, "non scalar key")
  Yaml.UnknownAlias anchor -> (Nothing, "unknown alias \"" ++ anchor ++ "\"")
  Yaml.UnexpectedEvent exptd unexptd ->
    ( Nothing
    , "unexpected event: expected " ++ show exptd
      ++ ", but received " ++ show unexptd
    )
  Yaml.InvalidYaml myerror -> case myerror of
    Nothing -> (Nothing, "unspecified error")
    Just yerror -> case yerror of
      Yaml.YamlException s -> (Nothing, s)
      Yaml.YamlParseException problem context mark ->
        ( Just (Yaml.yamlIndex mark)
        , case context of
            "" -> problem
            _  -> context ++ ", " ++ problem
        )
  Yaml.AesonException s -> (Nothing, s)
  Yaml.OtherParseException exc -> (Nothing, show exc)
  Yaml.NonStringKeyAlias anchor value ->
    ( Nothing
    , "non-string key alias; anchor name: " ++ anchor
      ++ ", value: " ++ show value
    )
  Yaml.CyclicIncludes -> (Nothing, "cyclic includes")
#if MIN_VERSION_yaml(0,11,1)
  Yaml.LoadSettingsException _ _ -> (Nothing, "loading settings exception")
#endif
#endif

emptyIspSpan :: Isp
emptyIspSpan = IspSpan 0 ""

normalizeListItems :: NonEmpty [Block Isp] -> NonEmpty [Block Isp]
normalizeListItems xs' =
  if getAny $ foldMap (foldMap (Any . isParagraph)) (drop 1 x :| xs)
    then fmap toParagraph <$> xs'
    else case x of
           [] -> xs'
           (y:ys) -> r $ (toNaked y : ys) :| xs
  where
    (x:|xs) = r xs'
    r = NE.reverse . fmap reverse
    isParagraph = \case
      OrderedList _ _ -> False
      UnorderedList _ -> False
      Naked         _ -> False
      _               -> True
    toParagraph (Naked inner) = Paragraph inner
    toParagraph other         = other
    toNaked (Paragraph inner) = Naked inner
    toNaked other             = other

succeeds :: Alternative m => m () -> m Bool
succeeds m = True <$ m <|> pure False

prependErr :: Int -> MMarkErr -> [Block Isp] -> [Block Isp]
prependErr o custom blocks = Naked (IspError err) : blocks
  where
    err = FancyError o (E.singleton $ ErrorCustom custom)

mailtoScheme :: URI.RText 'URI.Scheme
mailtoScheme = fromJust (URI.mkScheme "mailto")

toNesTokens :: Text -> NonEmpty Char
toNesTokens = NE.fromList . T.unpack

unexpEic :: MonadParsec e Text m => ErrorItem Char -> m a
unexpEic x = failure
  (Just x)
  (E.singleton . Label . NE.fromList $ "inline content")

nes :: a -> NonEmpty a
nes a = a :| []

fromRight :: Either a b -> b
fromRight (Right x) = x
fromRight _         =
  error "Text.MMark.Parser.fromRight: the impossible happened"

bakeText :: (String -> String) -> Text
bakeText = T.pack . reverse . ($ [])