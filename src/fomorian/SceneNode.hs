{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}

--
-- Scene node description as an F-algebra, which may open up some
-- useful functionality over Initial or Final encodings.
--

module Fomorian.SceneNode where

import Data.Kind (Constraint)
import Data.Functor.Foldable
import Data.Maybe
import qualified Data.Text as T

import qualified Data.Map as M
import qualified Data.Set as S

import Control.Monad
import Control.Monad.Reader
import Control.Applicative


-- qualify most of OpenGL stuff except for a few common types
import qualified Graphics.Rendering.OpenGL as GL
import Graphics.Rendering.OpenGL (($=))
import qualified Graphics.GLUtil as GLU

-- vinyl
import Data.Vinyl
import qualified Data.Constraint as DC

-- vinyl-gl
import qualified Graphics.VinylGL as VGL

import Fomorian.SceneResources

type Invocation tp sp =
  FieldRec '[
  '("shader", String),
  '("staticParameters", tp),
  '("frameParameters", sp),
  '("vertexBuffers", [VertexSourceData]),
  '("textures", [String])
  ]

--
-- @FrameData@ has two row types of parameters:
-- @sp@ is a set of "shader-ready" parameters. The types of these
-- values are those that can be passed into the shader for the given
-- renderer. Typically these are floats, ints, or vectors/matrices.
-- @np@ are not shader-ready, so they can be anything such as strings
-- or GADTs or f-algebras or whatever
--
data FrameData sp np cmd = FrameData sp np (DC.Dict (ShaderReady cmd sp))

class DrawMethod cmd where
  type ShaderReady cmd sp :: Constraint

data SceneNode sp np cmd x =
    forall tp . (Show tp, ShaderReady cmd tp) => Invoke (Invocation tp sp)
  | Group [x]
  | forall sp2 np2 sf2 nf2. (sp2 ~ FieldRec sf2, np2 ~ FieldRec nf2) => Transformer (FrameData sp np cmd -> FrameData sp2 np2 cmd) (SceneGraph sp2 np2 cmd)

instance (Show x, Show sp) => Show (SceneNode sp np cmd x) where
  show (Invoke iv) = "[Invoke:" ++ show iv ++ "]"
  show (Group cmds) = "[Group:" ++ show cmds ++ "]"
  show (Transformer _t _gr) = "[Transformer]"

instance Functor (SceneNode sp np cmd) where
  fmap _f (Invoke x) = Invoke x
  fmap f (Group cmds) = Group (fmap f cmds)
  fmap _f (Transformer t gr) = Transformer t gr
  


type SceneGraph sp np cmd = Fix (SceneNode sp np cmd)



foldAlgebra :: (Monoid m) => SceneNode sp np cmd m -> m
foldAlgebra (Invoke _x)         = mempty
foldAlgebra (Group cmds)       = foldr mappend mempty cmds
foldAlgebra (Transformer _t gr) = cata foldAlgebra gr

foldSceneGraph :: (Monoid m) => SceneGraph sp np cmd -> m
foldSceneGraph g = cata foldAlgebra g


--
-- DrawCmd is basically a ReaderT monad, where the input @r@
-- is the set of render parameters for the scene graph.
--


newtype DrawCmd r m a = DC { runDC :: r -> m a }

noopDraw :: (Monad m) => a -> DrawCmd r m a
noopDraw x = return x

instance (Functor m) => Functor (DrawCmd r m) where
  fmap f dc = DC $ \r -> fmap f (runDC dc r)

instance (Applicative m) => Applicative (DrawCmd r m) where
  pure x             = DC $ \_ -> pure x
  (DC fa) <*> (DC b) = DC $ \r -> (fa r) <*> (b r)

instance (Monad m) => Monad (DrawCmd r m) where
  return     = pure
  a >>= b    = DC $ \r -> do a' <- runDC a r
                             runDC (b a') r

instance (MonadIO m) => MonadIO (DrawCmd r m) where
  liftIO x = DC $ \_ -> liftIO x
  
instance (Alternative m) => Alternative (DrawCmd r m) where
  empty             = DC $ \_ -> empty
  (DC a) <|> (DC b) = DC $ \r -> (a r) <|> (b r)

instance (MonadPlus m) => MonadPlus (DrawCmd r m) where
  mzero     = DC $ \_ -> mzero
  mplus m n = DC $ \r -> mplus (runDC m r) (runDC n r)




--
-- Dump out text representation of a scene
--

data DumpScene

instance DrawMethod DumpScene where
  type ShaderReady DumpScene sp = (Show sp)


dumpAlgebra :: (MonadIO m) => SceneNode sp np DumpScene (DrawCmd (FrameData sp np DumpScene) m ()) -> DrawCmd (FrameData sp np DumpScene) m ()
dumpAlgebra (Invoke x)     = liftIO $ do putStrLn $ show (rvalf #shader x)
                                         return ()
dumpAlgebra (Group cmds)   = foldl (>>) (DC $ \_ -> return ()) cmds
dumpAlgebra (Transformer t gr) = DC $ \r ->
  let s = t r
      scmd = cata dumpAlgebra gr
  in runDC scmd s

dumpScene :: (MonadIO m) => SceneGraph sp np DumpScene-> DrawCmd (FrameData sp np DumpScene) m ()
dumpScene sg = cata dumpAlgebra sg

--
-- Find resources for a scene
--

--newtype OGLResources a = OGLResources { needsGLResources :: ResourceList }

oglResourcesAlgebra :: SceneNode sp np cmd ResourceList -> ResourceList
oglResourcesAlgebra (Invoke x) = ResourceList {
        shaderfiles =  S.singleton (rvalf #shader x), 
        vertexfiles =  S.fromList (rvalf #vertexBuffers x),
        texturefiles = S.fromList (rvalf #textures x)
      }
oglResourcesAlgebra (Group cmds) = foldl mergeResourceLists emptyResourceList cmds
oglResourcesAlgebra (Transformer _t gr) = oglResourcesScene gr

oglResourcesScene :: SceneGraph sp np cmd -> ResourceList
oglResourcesScene sg = cata oglResourcesAlgebra sg

--
-- Generate graphviz compatible text output
--

newtype VizText a = GViz { vizText :: T.Text }


graphVizAlgebra :: SceneNode sp np cmd T.Text -> T.Text
graphVizAlgebra (Invoke _x) = T.pack "[invoke]"
graphVizAlgebra (Group cmds) = T.concat cmds
graphVizAlgebra (Transformer _t gr) = graphVizScene gr

graphVizScene :: SceneGraph sp np cmd -> T.Text
graphVizScene sg = cata graphVizAlgebra sg

--
-- Drawing with OpenGL - shader parameters must be Uniform-valid, which
-- means they are GLfloat, GLint, vectors (V2,V3,V4) or matrices
--

data DrawGL

instance DrawMethod DrawGL where
  type ShaderReady DrawGL sp = (VGL.UniformFields sp)


invokeGL :: (sp ~ FieldRec sf) =>
  Invocation tp sp ->
  ReaderT ResourceMap (DrawCmd (FrameData sp np DrawGL) IO) ()
invokeGL ivk = ReaderT $ \rm -> DC $ \fd -> goInvoke ivk rm fd
  where
    goInvoke :: (sp ~ FieldRec sf) =>
      Invocation tp sp ->
      ResourceMap ->
      FrameData sp np DrawGL ->
      IO ()
    goInvoke ir rm (FrameData sp _np dc) = liftIO $ do
      let shaderdata = M.lookup (rvalf #shader ir) (shaders rm)
      case shaderdata of
        Nothing -> error "No shader loaded"
        Just shaderinstance -> do 
          GL.currentProgram $= Just (GLU.program shaderinstance)
          GLU.printErrorMsg "currentProgram"
          let vBufferValues = rvalf #vertexBuffers ir
          let v2Vertices = mapMaybe (\x -> M.lookup x (v2Buffers rm)) vBufferValues
          let texCoords = mapMaybe (\x -> M.lookup x (texCoordBuffers rm))  vBufferValues
          let v3Vertices = mapMaybe (\x -> M.lookup x (v3Buffers rm)) vBufferValues
          let indexVertices = mapMaybe (\x -> M.lookup x (indexBuffers rm)) vBufferValues
          let objVertices = mapMaybe (\x -> M.lookup x (objFileBuffers rm)) vBufferValues
          let textureObjects = mapMaybe (\x -> M.lookup x (textures rm)) (rvalf #textures ir)
          --VGL.setUniforms shaderinstance (rvalf #staticParameters ir)
          DC.withDict dc (VGL.setSomeUniforms shaderinstance sp) :: IO ()
          mapM_ (vertbind shaderinstance) v2Vertices
          GLU.printErrorMsg "v2Vertices"
          mapM_ (vertbind shaderinstance) texCoords
          GLU.printErrorMsg "texCoords"
          mapM_ (vertbind shaderinstance) v3Vertices
          GLU.printErrorMsg "v3Vertices"
          -- objVertices are tuples, the first element is the
          -- vertex buffer we want to vmap
          mapM_ ((vertbind shaderinstance) . fst) objVertices
          let allIndexBuffers = mappend indexVertices (map snd objVertices)
          mapM_ (\x -> GL.bindBuffer GL.ElementArrayBuffer $= Just (fst x)) allIndexBuffers
          GLU.printErrorMsg "indexVertices"
          --putStrLn $ show textureObjects
          GLU.withTextures2D textureObjects $ do
            --
            -- if an index array exists, use it via drawElements,
            -- otherwise just draw without an index array using drawArrays
            --
            if not (null allIndexBuffers)
            then do
              -- draw with drawElements
              --
              -- index arrays are Word32 which maps to GL type UnsignedInt
              -- need 'fromIntegral' to convert the count to GL.NumArrayIndices type
              let drawCount = (fromIntegral . snd . head $ allIndexBuffers)
              GL.drawElements GL.Triangles drawCount GL.UnsignedInt GLU.offset0
              GLU.printErrorMsg "drawElements"
            else do
              -- draw with drawArrays
              --
              -- we assume 2D drawing if 2d vertices are specified for this node,
              -- otherwise use 3D drawing
              if not (null v2Vertices) then
                GL.drawArrays GL.Triangles 0 (fromIntegral . snd . head $ v2Vertices)
              else
                GL.drawArrays GL.Triangles 0 (fromIntegral . snd . head $ v3Vertices)
              GLU.printErrorMsg "drawArrays"
            return ()

    --putStrLn $ "argh " ++ (rvalf #shader ir)
    --let labels = recordToList (getLabels ir)
    --mapM_ putStrLn labels
    --getLabels :: (AllFields ff) =>  FieldRec ff -> Rec (Data.Vinyl.Functor.Const String) ff
    --getLabels _ = rlabels
    --vertbind :: forall f a b. f ~ FieldRec a => GLU.ShaderProgram -> (f, b) -> IO ()
    vertbind shader v = do
        VGL.bindVertices $ fst v
        VGL.enableVertexFields shader (fst v)

openGLAlgebra :: (sp ~ FieldRec sf) =>
  SceneNode sp np DrawGL (ReaderT ResourceMap (DrawCmd (FrameData sp np DrawGL) IO) ()) ->
  (ReaderT ResourceMap (DrawCmd (FrameData sp np DrawGL) IO) ())
openGLAlgebra (Invoke x)     = invokeGL x
openGLAlgebra (Group cmds)   = foldl (>>) (ReaderT $ \_ -> noopDraw ()) cmds
openGLAlgebra (Transformer t gr) = ReaderT $ \rm ->
  DC $ \fd ->
         let fd2  = t fd
             (FrameData _sp2 _c2 dc2) = fd2 -- need the new set of constraints
             scmd = DC.withDict dc2 (cata openGLAlgebra gr)
             in runDC (runReaderT scmd rm) fd2
  
openGLgo :: SceneGraph (FieldRec sf) np DrawGL ->
  FrameData (FieldRec sf) np DrawGL ->
  ResourceMap ->
  IO ()
openGLgo sg sp rm = let sm = runReaderT (cata openGLAlgebra sg) rm
                    in runDC sm sp
                  

transformer :: forall sp np sp2 np2 sf2 nf2 cmd. (sp2 ~ FieldRec sf2, np2 ~ FieldRec nf2) =>
  (FrameData sp np cmd -> FrameData sp2 np2 cmd) ->
  (SceneGraph sp2 np2 cmd) ->
  Fix (SceneNode sp np cmd)
transformer t sg = Fix $ Transformer t sg

group :: [Fix (SceneNode sp np cmd)] -> Fix (SceneNode sp np cmd)
group xs = Fix $ Group xs

