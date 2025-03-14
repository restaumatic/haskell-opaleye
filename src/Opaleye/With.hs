{-# LANGUAGE FlexibleContexts #-}

module Opaleye.With
  ( with,
    withRecursive,

    -- * Explicit versions
    withExplicit,
    withRecursiveExplicit,
  )
where

import Control.Monad.Trans.State.Strict (State)
import Data.Profunctor.Product.Default (Default, def)
import Opaleye.Binary (unionAllExplicit)
import Opaleye.Internal.Binary (Binaryspec (..))
import qualified Opaleye.Internal.HaskellDB.PrimQuery as HPQ
import Opaleye.Internal.PackMap (PackMap (..))
import qualified Opaleye.Internal.PackMap as PM
import qualified Opaleye.Internal.PrimQuery as PQ
import Opaleye.Internal.QueryArr (Select, productQueryArr, runSimpleSelect)
import qualified Opaleye.Internal.Sql as Sql
import qualified Opaleye.Internal.Tag as Tag
import Opaleye.Internal.Unpackspec (Unpackspec (..), runUnpackspec)

with :: Default Unpackspec a a => Select a -> (Select a -> Select b) -> Select b
with = withExplicit def

-- | @withRecursive s f@ is the smallest set of rows @r@ such that
--
-- @
-- r == s \`'unionAll'\` (r >>= f)
-- @
withRecursive :: Default Binaryspec a a => Select a -> (a -> Select a) -> Select a
withRecursive = withRecursiveExplicit def

withExplicit :: Unpackspec a a -> Select a -> (Select a -> Select b) -> Select b
withExplicit unpackspec rhsSelect bodySelect = productQueryArr $ do
  withG unpackspec PQ.NonRecursive (\_ -> rhsSelect) bodySelect

withRecursiveExplicit :: Binaryspec a a -> Select a -> (a -> Select a) -> Select a
withRecursiveExplicit binaryspec base recursive = productQueryArr $ do
  let bodySelect selectCte = selectCte
  let rhsSelect selectCte = unionAllExplicit binaryspec base (selectCte >>= recursive)

  withG unpackspec PQ.Recursive rhsSelect bodySelect
  where
    unpackspec = binaryspecToUnpackspec binaryspec

withG ::
  Unpackspec a a ->
  PQ.Recursive ->
  (Select a -> Select a) ->
  (Select a -> Select b) ->
  State Tag.Tag (b, PQ.PrimQuery)
withG unpackspec recursive rhsSelect bodySelect = do
  (selectCte, withCte) <- freshCte unpackspec

  let rhsSelect' = rhsSelect selectCte
  let bodySelect' = bodySelect selectCte

  (_, rhsQ) <- runSimpleSelect rhsSelect'
  bodyQ <- runSimpleSelect bodySelect'

  pure (withCte recursive rhsQ bodyQ)

freshCte ::
  Unpackspec a a ->
  State
    Tag.Tag
    ( Select a,
      PQ.Recursive -> PQ.PrimQuery -> (b, PQ.PrimQuery) -> (b, PQ.PrimQuery)
    )
freshCte unpackspec = do
  cteName <- HPQ.Symbol "cte" <$> Tag.fresh

  -- TODO: Make a function that explicitly ignores its argument
  (cteColumns, cteBindings) <- do
    startTag <- Tag.fresh
    pure $
      PM.run $
        runUnpackspec unpackspec (PM.extractAttr "cte" startTag) (error "freshCte")

  let selectCte = productQueryArr $ do
        tag <- Tag.fresh
        let (renamedCte, renameCte) =
              PM.run $
                runUnpackspec unpackspec (PM.extractAttr "cte_renamed" tag) cteColumns

        pure (renamedCte, PQ.BaseTable (PQ.TableIdentifier Nothing (Sql.sqlSymbol cteName)) renameCte)

  pure
    ( selectCte,
      \recursive withQ (withedCols, withedQ) ->
        (withedCols, PQ.With recursive cteName (map fst cteBindings) withQ withedQ)
    )

binaryspecToUnpackspec :: Binaryspec a a -> Unpackspec a a
binaryspecToUnpackspec (Binaryspec (PackMap spec)) =
  Unpackspec $ PackMap $ \f a -> spec (\(pe, _) -> f pe) (a, a)
