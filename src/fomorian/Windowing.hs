{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Fomorian.Windowing 
(initWindow,
 initAppState,
 terminateWindow,
 renderLoop,
 AppInfo,
 AppAction(..)) where

import Graphics.Rendering.OpenGL as GL
import qualified Graphics.GLUtil as GLU
import qualified Graphics.UI.GLFW as GLFW

import Fomorian.SceneResources
import Fomorian.SceneNode
import Fomorian.Common

import Data.Vinyl
import qualified Data.Constraint as DC

import Data.IORef
import Control.Monad
import Control.Lens ( (%~) )

type AppInfo s = FieldRec '[
      '("window", GLFW.Window)
    , '("windowSize", (Int,Int))
    , '("resources", ResourceMap)
    , '("curTime", Float)
    , '("appState", s)
    ]

data AppAction = NextFrame | EndApp 
    deriving (Eq, Show)

resizeWindow :: IORef (AppInfo s) -> GLFW.WindowSizeCallback
resizeWindow s = \_ w h -> windowResizeEvent s w h
    
windowResizeEvent :: IORef (AppInfo s) -> Int -> Int -> IO ()
windowResizeEvent s w h = do
    GL.viewport $= (GL.Position 0 0, GL.Size (fromIntegral w) (fromIntegral h))
    modifyIORef' s $ rputf #windowSize (w,h)

initWindow :: (Int,Int,String) -> IO GLFW.Window
initWindow (w,h,title) = do
    result <- GLFW.init
    if (result == False)
    then error "GLFW init failed"
    else do
        GLFW.defaultWindowHints
        GLFW.windowHint (GLFW.WindowHint'ContextVersionMajor 4)
        GLFW.windowHint (GLFW.WindowHint'Resizable True)
        GLFW.windowHint (GLFW.WindowHint'OpenGLProfile GLFW.OpenGLProfile'Core)
        Just win <- GLFW.createWindow w h title Nothing Nothing
        GLFW.makeContextCurrent (Just win)
        GLFW.swapInterval 1      -- should wait for vsync, set to 0 to not wait
        return win

initAppState :: (Int,Int,String) -> GLFW.Window -> s -> IO (IORef (AppInfo s))
initAppState (w,h,_title) window initialState = do
    defaultVAO <- fmap head (genObjectNames 1)
    bindVertexArrayObject $= Just defaultVAO
    GLU.printErrorMsg "bindVAO"
    appIORef <- newIORef $ (#window =: window)
                        :& (#windowSize =: (w,h))
                        :& (#resources =: emptyResourceMap)
                        :& (#curTime =: (0 :: Float))
                        :& (#appState =: initialState)
                        :& RNil
    GLFW.setWindowSizeCallback window (Just $ resizeWindow appIORef)
    return appIORef

  
terminateWindow :: GLFW.Window -> IO ()
terminateWindow win = do
    GLFW.destroyWindow win
    GLFW.terminate

shouldEndProgram :: GLFW.Window -> IO Bool
shouldEndProgram win = do
    p <- GLFW.getKey win GLFW.Key'Escape
    GLFW.pollEvents
    windowKill <- GLFW.windowShouldClose win
    return (p == GLFW.KeyState'Pressed ||  windowKill)

renderApp ::
        ResourceMap
    ->  SceneGraph (FieldRec '[]) TopWindowFrameParams DrawGL
    ->  TopWindowFrameParams
    ->  IO ()
renderApp resources scene windowparams = do
    let framedata = FrameData RNil windowparams DC.Dict
    GL.clearColor $= Color4 0.1 0.1 0.1 1
    GL.clear [GL.ColorBuffer, GL.DepthBuffer]
    depthFunc $= Just Less
    cullFace $= Just Front
    openGLgo scene framedata resources
    return ()      


renderLoop ::
        IORef (AppInfo s)
    ->  (s -> SceneGraph (FieldRec '[]) TopWindowFrameParams DrawGL)
    ->  (AppInfo s -> TopWindowFrameParams)
    ->  (AppInfo s -> (s, AppAction))
    ->  IO ()
renderLoop appref buildScene genRP advanceState = 
    loop
  where
    loop = do
        appData <- readIORef appref
        let (appState', appAction) = advanceState appData
        let win = rvalf #window appData
        let resources = rvalf #resources appData
        let scene = buildScene appState'
        let needresources = oglResourcesScene $ buildScene appState'
        resources' <- loadResources needresources resources

        let new_appInfo =   (rlensf #curTime %~ (+0.016))
                          . (rputf #resources resources')
                          . (rputf #appState appState' )
                          $ appData

        let frame_data = genRP new_appInfo

        renderApp resources' scene frame_data
        writeIORef appref new_appInfo

        GLFW.swapBuffers win
        externalClose <- shouldEndProgram win
        let shouldClose = (appAction == EndApp) || externalClose
        unless shouldClose loop
