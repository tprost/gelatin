module Gelatin.Core.Fill (
    -- * Smart Constructors
    solid,
    -- * Types
    Fill(..),
    FillHash(..)
) where

import Gelatin.Core.Color
import Gelatin.Core.Bounds
import Gelatin.Core.Transform
import Data.Hashable
import qualified Data.Map.Strict as M
import Data.Map (Map)
import Data.List (sortBy, sort)
import GHC.Generics
import Linear
--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------
data Fill = FillColor (V2 Float -> V4 Float)
          | FillTexture FilePath (V2 Float -> V2 Float)

data FillHash = FillHash Fill [V2 Float]

instance Hashable FillHash where
    hashWithSalt s (FillHash (FillColor f) vs) =
        s `hashWithSalt` "FillColor" `hashWithSalt` map f vs
    hashWithSalt s (FillHash (FillTexture fp f) vs) =
        s `hashWithSalt` "FillTexture" `hashWithSalt` fp `hashWithSalt` map f vs

instance Show Fill where
    show (FillColor _) = "FillColor{ V2 Float -> V4 Float }"
    show (FillTexture fp _) = "FillTexture{ " ++ fp ++ " (V2 Float -> V2 Float) }"
--------------------------------------------------------------------------------
-- Smart constructors
--------------------------------------------------------------------------------
solid :: Color -> Fill
solid = FillColor . const 
