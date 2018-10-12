{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
module Kaleidogen where

import Reflex.Dom.FragmentShaderCanvas
import Reflex.Dom

import qualified Data.Text as T
import Data.Bifunctor
import Data.Monoid
import Data.List
import Data.Maybe
import Control.Monad.Fix
import Control.Monad.Random.Class

import Expression
import GLSL
import DNA
import qualified SBNL as S

stateMachine :: (MonadFix m, MonadHold t m, Reflex t) =>
    a -> [Event t (a -> a)] -> m (Dynamic t a)
stateMachine x es = foldDyn ($) x $ mergeWith (.) es


selectNList ::
    forall t a b m.
    (Adjustable t m, DomBuilder t m, MonadFix m, PostBuild t m, MonadHold t m, Ord a) =>
    Int ->
    Event t () ->
    Dynamic t [a] ->
    (Dynamic t a -> m b) ->
    m (Event t [a], Dynamic t [b])
selectNList n eClear dxs act = mdo
    -- TODO: This currently only works if the input is is only appended to, but
    -- not if elements is deleted. If we need that, we should update the selected set
    let eSelection :: Event t (S.SBNL a) = attachWith (S.flipMember n) (current dSelected) eClicks
    -- This separation is necessary so that eClear may depend on the eSelectedN
    -- that we return; otherwise we get a loop
    let eClearedSelection :: Event t (S.SBNL a) = leftmost [S.empty <$ eClear, eSelection]
    dSelected :: Dynamic t (S.SBNL a) <- holdDyn S.empty eClearedSelection

    let dxs' = (\s -> map (\x -> (x `S.member` s, x))) <$> dSelected <*> dxs
    dstuff <- simpleList dxs' $ \dx' -> do
        enabled <- holdUniqDyn (fst <$> dx')
        dx      <- holdUniqDyn (snd <$> dx')
        let attrs = (\case { True -> "class" =: "selected" ; False -> mempty}) <$> enabled
        (eClick,dy) <- clickable $ elDynAttr' "div" attrs $ act dx
        let eTaggedClick = tag (current dx) eClick
        return (eTaggedClick, dy)
    let eClicks = switch (current (leftmost . fmap fst <$> dstuff))
    let dys = fmap snd <$> dstuff
    return (eSelection, dys)

-- | A div class with an event to make it scroll all the way to the right.
-- | Does not work yet, postposed right now
scrollRightDivClass :: (MonadHold t m, PostBuild t m, DomBuilder t m) => Event t () -> T.Text -> m a -> m a
scrollRightDivClass e cls act = do
    attrs <- holdDyn mempty ("scrollLeft" =: "10000" <$ e)
    let attrs' = ("class" =: cls <>) <$> attrs
    elDynAttr "div" attrs' act

patternCanvans :: MonadWidget t m => Dynamic t DNA -> m (Dynamic t (Maybe T.Text))
patternCanvans dGenome = patternCanvansMay (Just <$> dGenome)

patternCanvansMay :: MonadWidget t m => Dynamic t (Maybe DNA) -> m (Dynamic t (Maybe T.Text))
patternCanvansMay dGenome = do
    let dShader = T.pack . maybe blankShader (toFragmentShader . dna2rna) <$> dGenome
    -- let showTitle dna = T.pack $ unlines [show dna, show (dna2rna dna)]
    let showTitle dna = T.pack . maybe "" show $ dna
    elDynAttr "div" ((\dna -> "title" =: showTitle dna) <$> dGenome) $ do
        let attrs = mconcat
                [ "width"  =: "1000"
                , "height" =: "1000"
                ]
        fragmentShaderCanvas attrs dShader

clickable :: (HasDomEvent t el 'ClickTag, Functor f) =>
   f (el, c) -> f (Event t (DomEventType el 'ClickTag), c)
clickable act = first (domEvent Click) <$> act

divClass' :: DomBuilder t m =>
    T.Text ->
    m a ->
    m (Element EventResult (DomBuilderSpace m) t, a)
divClass' cls act = elAttr' "div" ("class" =: cls) act


type Seed = Int

preview :: Seed -> [DNA] -> Maybe DNA
preview _    []    = Nothing
preview _    [x]   = Just x
preview seed [x,y] = Just $ crossover seed x y
preview _ _ = Nothing -- Should not be possible

toolbarButton :: (DomBuilder t m, PostBuild t m) =>
    T.Text -> Dynamic t Bool -> m (Event t ())
toolbarButton txt dActive = do
    let dAttrs = (\case True -> mempty; False -> "class" =: "disabled") <$> dActive
    (e,_) <- elDynAttr' "a" dAttrs (text txt)
    return $ domEvent Click e

main :: IO ()
main = do
  seed <- getRandom
  mainWidgetWithHead htmlHead $
    elAttr "div" ("align" =: "center") $ mdo
        (eAdded1, eDelete, _eSave) <- divClass "toolbar" $
            (,,) <$>
            toolbarButton "➕" dCanAdd <*>
            toolbarButton "🗑" dCanDel <*>
            toolbarButton "💾" dCanSave

        (eAdded2, _) <- clickable $ divClass' "new-pat" $ patternCanvansMay dNewGenome

        let eAdded = eAdded1 <> eAdded2

        let dCanAdd = (\new xs -> maybe False (`notElem` xs) new) <$> dNewGenome <*> dGenomes
        let dCanDel = (\new xs -> maybe False (`elem`    xs) new) <$> dNewGenome <*> dGenomes
        let dCanSave = isJust <$> dNewGenome

        (ePairSelected, _dErrors) <- divClass "patterns" $ do
            selectNList 2 (eAdded <> eDelete) dGenomes $ patternCanvans

        {-
        inp <- textArea $ def
           & textAreaConfig_initialValue .~ "1 2"
           & textAreaConfig_attributes .~ (return ("style"  =: "width:80%"))
           -- & textAreaConfig_setValue .~ updated (T.unlines <$> genomes)
        --let genomes = T.lines <$> _textArea_value inp

        el "pre" $ dynText (T.unlines <$> genomes)
        -}
        dPairSelected <- holdDyn (take 1 initialDNAs) $ mconcat
            [ ePairSelected
            , [] <$ eAdded
            , [] <$ eDelete
            ]

        let dNewGenome = preview seed <$> dPairSelected

        dGenomes <- foldDyn id initialDNAs $ mconcat
            [ (\new xs -> nub $ xs ++ [new]) <$>
                    fmapMaybe id (tag (current dNewGenome) eAdded)
            , (\new xs -> delete new xs) <$>
                    fmapMaybe id (tag (current dNewGenome) eDelete)
            ]


        {- WebGL debugging
        el "br" blank
        elAttr "div" (mconcat
            [ ("style"  =: "width:80%; text-align: left; white-space:pre; font-family:mono")
            ]) $
          dynText (dErrors >>= sequence >>= return . foldMap (foldMap id))
        -}
        return ()
  where
    htmlHead :: DomBuilder t m => m ()
    htmlHead = do
        el "style" (text css)
        el "title" (text "Kaleidogen")

css :: T.Text
css = T.unlines
    [ "html {"
    , "  margin: 0;"
    , "  height: 100%;"
    , "}"
    , "body {"
    , "  display: flex;"
    , "  margin: 0;"
    , "  height: 100%;"
    , "  flex-direction: column;"
    , "}"
    , ".toolbar {"
    , "  height:10vh;"
    , "}"
    , ".toolbar a {"
    , "  display:inline-block;"
    , "  margin:1vh 2vh;"
    , "  border:none;"
    , "  padding:.5vh;"
    , "  font-size:6vh;"
    , "  width:8vh;"
    , "  height:8vh;"
    , "  background-color:lightblue;"
    , "  border-radius: 1vh;"
    , "}"
    , ".toolbar a.disabled {"
    , "  background-color:lightgrey;"
    , "  color:white;"
    , "}"
    , ".patterns {"
    , "  margin:0;"
    , "  height:40vh;"
    , "  width:100%;"
    , "  display: flex;"
    , "  flex-wrap: wrap;"
    , "  justify-content: space-evenly;" -- does not work yet
    , "  align-content: flex-start;"
    , "  overflow-y: auto;"
    , "}"
    , ".patterns canvas {"
    , "  height:10vh;"
    , "  margin:2vh;"
    , "}"
    , ".new-pat canvas {"
    , "  height:45vh;"
    , "  margin:2vh;"
    , "}"
    , ".patterns canvas {"
    , "  border: 3px solid white;"
    , "}"
    , ".patterns .selected  canvas {"
    , "  border: 3px solid blue;"
    , "}"
    ]


