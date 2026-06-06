{- | The six pure, total domain operations (CORE-01) every propagator and the search loop
call. None use 'error' or a partial pattern match: an absent variable reads as an empty
domain, and the singleton lookup is total. Totality here is what lets the layers above
reason about conflict and assignment without guarding against crashes.
-}
module Lattice.Core.Domain (
  domainOf,
  removeValue,
  assign,
  isEmpty,
  singletonValue,
  unassignedVars,
) where

import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Lattice.Core.Types (Domain (..), Domains, Value, Var)

{- | The domain stored for a variable, or the empty domain if it is absent (total, never a
partial lookup). Encoders seed every variable, so the default only guards misuse.
-}
domainOf :: Var -> Domains -> Domain
domainOf = IntMap.findWithDefault (Domain IntSet.empty)

{- | Remove a value from a variable's domain. Idempotent: 'IntSet.delete' of an absent value
is the identity, so removing twice equals removing once.
-}
removeValue :: Value -> Var -> Domains -> Domains
removeValue x = IntMap.adjust (\(Domain s) -> Domain (IntSet.delete x s))

-- | Pin a variable to a single value: replace its domain with the singleton @{x}@.
assign :: Var -> Value -> Domains -> Domains
assign v x = IntMap.insert v (Domain (IntSet.singleton x))

-- | True iff the domain has no values left — the conflict signal the queue watches for.
isEmpty :: Domain -> Bool
isEmpty (Domain s) = IntSet.null s

-- | The sole value of a singleton domain, or 'Nothing' when the size is not exactly one.
singletonValue :: Domain -> Maybe Value
singletonValue (Domain s) = case IntSet.toList s of
  [x] -> Just x
  _ -> Nothing

-- | Variables not yet decided (domain size greater than one), in ascending index order.
unassignedVars :: Domains -> [Var]
unassignedVars ds = [v | (v, Domain s) <- IntMap.toAscList ds, IntSet.size s > 1]
