{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module Gelatin.GL.Renderer.R2
  ( -- * Line rendering
    colorPolylineRenderer
  , texPolylineRenderer
    -- * Triangle rendering
  , colorRenderer
  , textureRenderer
    -- * Bezier rendering
  , colorBezRenderer
  , textureBezRenderer
    -- * Masking
  , maskRenderer
  , alphaMask
    -- * Transforming a rendering
  , transformRenderer
    -- * Uniform updates
  , updatePrimitive
  , updateModelView
  , updateThickness
  , updateFeather
  , updateSumLength
  , updateCap
  , updateHasUV
  , updateSampler
  , updateMainTex
  , updateMaskTex
  , updateAlpha
  , updateMultiply
  , updateShouldReplaceColor
  , updateReplacementColor
  ) where

import           Data.Proxy                 (Proxy (..))
import           Data.Vector.Unboxed        (Vector)
import qualified Data.Vector.Unboxed        as V
import           Foreign.Marshal.Array
import           Foreign.Marshal.Utils
import           Graphics.GL.Core33
import           Graphics.GL.Types
--------------------------------------------------------------------------------
import           Gelatin
import           Gelatin.Shaders
import           Gelatin.Shaders.Simple2D   (PrimType (..),
                                             Simple2DAttribBuffers,
                                             Simple2DAttribToggles,
                                             Simple2DUniforms)
--------------------------------------------------------------------------------
import           Gelatin.GL.Renderer.Common
import           Gelatin.GL.Shader
--------------------------------------------------------------------------------
-- Uniform updates for the Simple2DShader
--------------------------------------------------------------------------------
updatePrimitive :: GLuint -> PrimType -> IO ()
updateProjection :: GLuint -> M44 Float -> IO ()
updateModelView :: GLuint -> M44 Float -> IO ()
updateThickness :: GLuint -> Float -> IO ()
updateFeather :: GLuint -> Float -> IO ()
updateSumLength :: GLuint -> Float -> IO ()
updateCap :: GLuint -> (LineCap, LineCap) -> IO ()
updateHasUV :: GLuint -> Bool -> IO ()
updateSampler :: GLuint -> Int -> IO ()
updateMainTex :: GLuint -> Int -> IO ()
updateMaskTex :: GLuint -> Int -> IO ()
updateAlpha :: GLuint -> Float -> IO ()
updateMultiply :: GLuint -> V4 Float -> IO ()
updateShouldReplaceColor :: GLuint -> Bool -> IO ()
updateReplacementColor :: GLuint -> V4 Float -> IO ()
updatePrimitive
  :& updateProjection
  :& updateModelView
  :& updateThickness
  :& updateFeather
  :& updateSumLength
  :& updateCap
  :& updateHasUV
  :& updateSampler
  :& updateMainTex
  :& updateMaskTex
  :& updateAlpha
  :& updateMultiply
  :& updateShouldReplaceColor
  :& updateReplacementColor
  :& () = genFunction (Proxy :: Proxy Simple2DUniforms)
--------------------------------------------------------------------------------
-- Attribute toggling
--------------------------------------------------------------------------------
enablePosition :: IO ()
disablePosition :: IO ()
enableColor :: IO ()
disableColor :: IO ()
enableUV :: IO ()
disableUV :: IO ()
enableBez :: IO ()
disableBez :: IO ()
enableBezUV :: IO ()
disableBezUV :: IO ()
enablePrev :: IO ()
disablePrev :: IO ()
enableNext :: IO ()
disableNext :: IO ()
(enablePosition, disablePosition)
  :& (enableColor, disableColor)
  :& (enableUV, disableUV)
  :& (enableBez, disableBez)
  :& (enableBezUV, disableBezUV)
  :& (enablePrev, disablePrev)
  :& (enableNext, disableNext)
  :& () = genFunction (Proxy :: Proxy Simple2DAttribToggles)

disableAll :: IO ()
disableAll =
  sequence_ [ disablePosition, disableColor, disableUV, disableBez, disableBezUV
            , disablePrev, disableNext
            ]

enableAttribsForLines :: Bool -> IO ()
enableAttribsForLines hasUV = do
  disableAll
  enablePosition
  enableBezUV
  enablePrev
  enableNext
  if hasUV
    then enableUV
    else enableColor

enableAttribsForTris :: Bool -> IO ()
enableAttribsForTris hasUV =
  disableAll >> enablePosition >> if hasUV then enableUV
                                           else enableColor

enableAttribsForBezs :: Bool -> IO ()
enableAttribsForBezs hasUV =
  disableAll >> enablePosition >> enableBez >> if hasUV then enableUV
                                                        else enableColor

enableAttribsForMask :: IO ()
enableAttribsForMask = disableAll >> enablePosition >> enableUV
--------------------------------------------------------------------------------
-- Attribute buffering
--------------------------------------------------------------------------------
bufferPosition :: GLint -> GLuint -> Vector (V2 Float) -> IO ()
bufferColor :: GLint -> GLuint -> Vector (V4 Float) -> IO ()
bufferUV :: GLint -> GLuint -> Vector (V2 Float) -> IO ()
bufferBez :: GLint -> GLuint -> Vector (V3 Float) -> IO ()
bufferBezUV :: GLint -> GLuint -> Vector (V2 Float) -> IO ()
bufferPrev :: GLint -> GLuint -> Vector (V2 Float) -> IO ()
bufferNext :: GLint -> GLuint -> Vector (V2 Float) -> IO ()
bufferPosition
  :& bufferColor
  :& bufferUV
  :& bufferBez
  :& bufferBezUV
  :& bufferPrev
  :& bufferNext
  :& () = genFunction (Proxy :: Proxy Simple2DAttribBuffers)
--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------
-- | Creates and returns a renderer that renders a colored, expanded 2d polyline
-- projected in 2d space.
colorPolylineRenderer :: Context -> Simple2DShader -> Float -> Float
                      -> (LineCap,LineCap) -> Vector (V2 Float)
                      -> Vector (V4 Float) -> IO Renderer2
colorPolylineRenderer win sh thickness feather caps verts colors = do
  let empty = putStrLn "could not expand polyline" >> return mempty
      mpoly = expandPolyline verts colors thickness feather
  flip (maybe empty) mpoly $ \(vs_,cs_,us_,ns_,ps_,totalLen) -> do
    let toFrac :: Float -> GLfloat
        toFrac = realToFrac
        vs = V.map (fmap toFrac) vs_
        cs = V.map (fmap toFrac) cs_
        uvs = V.map (fmap toFrac) cs_
        us = V.map (fmap toFrac) us_
        ns = V.map (fmap toFrac) ns_
        ps = V.map (fmap toFrac) ps_

    withVAO $ \vao -> withBuffers 5 $ \bufs@[vbuf, cbuf, buvbuf, nbuf, pbuf] -> do
      enableAttribsForLines False
      bufferPosition 2 vbuf vs
      bufferColor 4 cbuf cs
      bufferBezUV 2 buvbuf us
      bufferNext 2 nbuf ns
      bufferPrev 2 pbuf ps
      glBindVertexArray 0

      let num = fromIntegral $ V.length vs_
          r t = do
            glUseProgram sh
            let (mv, a, m, mr) = unwrapTransforms2 t
            pj <- orthoContextProjection win
            updatePrimitive sh PrimLine
            updateModelView sh mv
            updateHasUV sh False
            updateThickness sh thickness
            updateFeather sh feather
            updateSumLength sh totalLen
            updateCap sh caps
            updateAlpha sh a
            updateMultiply sh m
            case mr of
              Just c -> do updateShouldReplaceColor sh True
                           updateReplacementColor sh c
              _      -> updateShouldReplaceColor sh False
            drawBuffer sh vao GL_TRIANGLE_STRIP num
          c = do withArray bufs $ glDeleteBuffers 5
                 withArray [vao] $ glDeleteVertexArrays 1
      return (c,r)

-- | Creates and returns a renderer that renders a textured, expanded 2d
-- polyline projected in 2d space.
texPolylineRenderer :: Context -> Simple2DShader -> Float
                    -> Float -> (LineCap,LineCap) -> Vector (V2 Float)
                    -> Vector (V2 Float) -> IO Renderer2
texPolylineRenderer win sh thickness feather caps verts uvs = do
  let empty = putStrLn "could not expand polyline" >> return mempty
      mpoly = expandPolyline verts uvs thickness feather
  flip (maybe empty) mpoly $ \(vs_,cs_,us_,ns_,ps_,totalLen) -> do
    let toFrac :: Float -> GLfloat
        toFrac = realToFrac
        vs = V.map (fmap toFrac) vs_
        cs = V.map (fmap toFrac) cs_
        uvs = V.map (fmap toFrac) cs_
        us = V.map (fmap toFrac) us_
        ns = V.map (fmap toFrac) ns_
        ps = V.map (fmap toFrac) ps_

    withVAO $ \vao -> withBuffers 5 $ \bufs@[vbuf, cbuf, buvbuf, nbuf, pbuf] -> do
      enableAttribsForLines True
      bufferPosition 2 vbuf vs
      bufferUV 2 cbuf cs
      bufferBezUV 2 buvbuf us
      bufferNext 2 nbuf ns
      bufferPrev 2 pbuf ps
      glBindVertexArray 0

      let num = fromIntegral $ V.length vs_
          r t = do
            glUseProgram sh
            let (mv, a, m, mr) = unwrapTransforms2 t
            pj <- orthoContextProjection win
            updatePrimitive sh PrimLine
            updateProjection sh pj
            updateModelView sh mv
            updateHasUV sh True
            updateThickness sh thickness
            updateFeather sh feather
            updateSumLength sh totalLen
            updateCap sh caps
            updateAlpha sh a
            updateMultiply sh m
            case mr of
              Just c -> do updateShouldReplaceColor sh True
                           updateReplacementColor sh c
              _      -> updateShouldReplaceColor sh False
            drawBuffer sh vao GL_TRIANGLE_STRIP num
          c = do withArray bufs $ glDeleteBuffers 5
                 withArray [vao] $ glDeleteVertexArrays 1
      return (c,r)

-- | Creates and returns a renderer that renders the given colored
-- geometry.
colorRenderer :: Context -> Simple2DShader -> GLuint -> Vector (V2 Float)
              -> Vector (V4 Float) -> IO Renderer2
colorRenderer window sh mode vs gs =
  withVAO $ \vao -> withBuffers 2 $ \[pbuf,cbuf] -> do
    enableAttribsForTris False
    clearErrors "colorRenderer: enable attribs"
    bufferPosition 2 pbuf vs
    clearErrors "colorRenderer: buffer position"
    bufferColor 4 cbuf $ V.take (V.length vs) gs
    clearErrors "colorRenderer: buffer color"
    let num = fromIntegral $ V.length vs
        renderFunction t = do
          glUseProgram sh
          let (mv,a,m,mr) = unwrapTransforms2 t
          pj <- orthoContextProjection window
          updatePrimitive sh PrimTri
          updateProjection sh pj
          updateModelView sh mv
          updateHasUV sh False
          updateAlpha sh a
          updateMultiply sh m
          case mr of
            Just c -> do updateShouldReplaceColor sh True
                         updateReplacementColor sh c
            _      -> updateShouldReplaceColor sh False
          drawBuffer sh vao mode num
        cleanupFunction = do
          withArray [pbuf, cbuf] $ glDeleteBuffers 2
          withArray [vao] $ glDeleteVertexArrays 1
    return (cleanupFunction,renderFunction)

-- | Creates and returns a renderer that renders a textured
-- geometry.
textureRenderer :: Context -> Simple2DShader -> GLuint -> Vector (V2 Float)
                -> Vector (V2 Float) -> IO Renderer2
textureRenderer win sh mode vs uvs =
  withVAO $ \vao -> withBuffers 2 $ \[pbuf,cbuf] -> do
    enableAttribsForTris True
    bufferPosition 2 pbuf vs
    bufferUV 2 cbuf uvs
    glBindVertexArray 0

    let num = fromIntegral $ V.length vs
        renderFunction t = do
          glUseProgram sh
          let (mv,a,m,mr) = unwrapTransforms2 t
          pj <- orthoContextProjection win
          updatePrimitive sh PrimTri
          updateProjection sh pj
          updateModelView sh mv
          updateHasUV sh True
          updateSampler sh 0
          updateAlpha sh a
          updateMultiply sh m
          case mr of
            Just c -> do updateShouldReplaceColor sh True
                         updateReplacementColor sh c
            _      -> updateShouldReplaceColor sh False
          drawBuffer sh vao mode num
        cleanupFunction = do
          withArray [pbuf, cbuf] $ glDeleteBuffers 2
          withArray [vao] $ glDeleteVertexArrays 1
    return (cleanupFunction,renderFunction)

bezWinding :: Vector (V2 Float) -> Vector (V3 Float)
bezWinding vs = V.concatMap getWinding $ V.generate numBezs id
  where getWinding i =
          let n = i * 3
              (a,b,c) = (vs V.! n, vs V.! (n + 1), vs V.! (n + 2))
              w = fromBool $ triangleArea a b c <= 0
          in V.fromList [ V3 0 0 w
                        , V3 0.5 0 w
                        , V3 1 1 w
                        ]
        numBezs = floor $ realToFrac (V.length vs) / (3 :: Double)

-- | Creates and returns a renderer that renders the given colored beziers.
colorBezRenderer :: Context -> Simple2DShader
                 -> Vector (V2 Float) -> Vector (V4 Float) -> IO Renderer2
colorBezRenderer win sh vs cs = do
  let ws = bezWinding vs
  withVAO $ \vao -> withBuffers 3 $ \[pbuf, tbuf, cbuf] -> do
    enableAttribsForBezs False
    bufferPosition 2 pbuf vs
    bufferBez 3 tbuf ws
    bufferColor 4 cbuf $ V.take (V.length vs) cs
    glBindVertexArray 0

    let cleanupFunction = do
          withArray [pbuf, tbuf, cbuf] $ glDeleteBuffers 3
          withArray [vao] $ glDeleteVertexArrays 1
        num = fromIntegral $ V.length vs
        renderFunction t = do
          glUseProgram sh
          pj <- orthoContextProjection win
          let (mv,a,m,mr) = unwrapTransforms2 t
          updatePrimitive sh PrimBez
          updateProjection sh pj
          updateModelView sh mv
          updateHasUV sh False
          updateAlpha sh a
          updateMultiply sh m
          case mr of
            Just c -> do updateShouldReplaceColor sh True
                         updateReplacementColor sh c
            _      -> updateShouldReplaceColor sh False
          drawBuffer sh vao GL_TRIANGLES num
    return (cleanupFunction,renderFunction)

-- | Creates and returns a renderer that renders the given textured beziers.
textureBezRenderer :: Context -> Simple2DShader
                   -> Vector (V2 Float) -> Vector (V2 Float) -> IO Renderer2
textureBezRenderer win sh vs cs = do
  let ws = bezWinding vs
  withVAO $ \vao -> withBuffers 3 $ \[pbuf, tbuf, cbuf] -> do
    enableAttribsForBezs True
    bufferPosition 2 pbuf vs
    bufferBez 3 tbuf ws
    bufferUV 2 cbuf cs
    glBindVertexArray 0

    let cleanupFunction = do
            withArray [pbuf, tbuf, cbuf] $ glDeleteBuffers 3
            withArray [vao] $ glDeleteVertexArrays 1
        num = fromIntegral $ V.length vs
        renderFunction t = do
          glUseProgram sh
          pj <- orthoContextProjection win
          let (mv,a,m,mr) = unwrapTransforms2 t
          updatePrimitive sh PrimBez
          updateProjection sh pj
          updateModelView sh mv
          updateHasUV sh True
          updateSampler sh 0
          updateAlpha sh a
          updateMultiply sh m
          case mr of
            Just c -> do updateShouldReplaceColor sh True
                         updateReplacementColor sh c
            _      -> updateShouldReplaceColor sh False
          drawBuffer sh vao GL_TRIANGLES num
    return (cleanupFunction,renderFunction)

-- | Creates and returns a renderer that masks a textured rectangular area with
-- another texture.
maskRenderer :: Context -> Simple2DShader -> GLuint -> Vector (V2 Float)
             -> Vector (V2 Float) -> IO Renderer2
maskRenderer win sh mode vs uvs =
    withVAO $ \vao -> withBuffers 2 $ \[pbuf, uvbuf] -> do
        enableAttribsForMask
        bufferPosition 2 pbuf vs
        bufferUV 2 uvbuf uvs
        glBindVertexArray 0

        let cleanup = do withArray [pbuf, uvbuf] $ glDeleteBuffers 2
                         withArray [vao] $ glDeleteVertexArrays 1
            num = fromIntegral $ V.length vs
            render t = do
                let (mv,a,m,_) = unwrapTransforms2 t
                pj <- orthoContextProjection win
                --updateUniformsForMask (unShader sh) pj mv a m 0 1
                updateProjection sh pj
                updateModelView sh mv
                updateAlpha sh a
                updateMultiply sh m
                updateMainTex sh 0
                updateMaskTex sh 1
                drawBuffer sh vao mode num
        return (cleanup,render)

-- | Creates a rendering that masks an IO () drawing computation with the alpha
-- value of another.
alphaMask :: Context -> Simple2DShader -> IO () -> IO () -> IO Renderer2
alphaMask win mrs r2 r1 = do
    mainTex <- toTextureUnit (Just GL_TEXTURE0) win r2
    maskTex <- toTextureUnit (Just GL_TEXTURE1) win r1
    (w,h)   <- ctxWindowSize win
    let vs = V.fromList $ map (fmap fromIntegral) [V2 0 0, V2 w 0, V2 w h, V2 0 h]
        uvs = V.fromList [V2 0 1, V2 1 1, V2 1 0, V2 0 0]
    (c,f) <- maskRenderer win mrs GL_TRIANGLE_FAN vs uvs
    let f' _ = do glActiveTexture GL_TEXTURE0
                  glBindTexture GL_TEXTURE_2D mainTex
                  glActiveTexture GL_TEXTURE1
                  glBindTexture GL_TEXTURE_2D maskTex
        c'    = withArray [mainTex,maskTex] $ glDeleteTextures 2
        f'' _ = do glActiveTexture GL_TEXTURE0
                   glBindTexture GL_TEXTURE_2D 0
                   glActiveTexture GL_TEXTURE1
                   glBindTexture GL_TEXTURE_2D 0
    return (c >> c', \t -> f' t >> f t >> f'' t)

transformRenderer :: [RenderTransform2] -> Renderer2 -> Renderer2
transformRenderer ts (c, r) = (c, r . (ts ++))