{-# LANGUAGE CPP #-}

#ifndef MIN_VERSION_base
#defined MIN_VERSION_base(x,y,z) 1
#endif

-- Copyright 2009-2010 Corey O'Connor
module Graphics.Vty.Output.XTermColor ( reserveTerminal )
    where

import Graphics.Vty.Output.Interface
import Graphics.Vty.Input.Mouse
import qualified Graphics.Vty.Output.TerminfoBased as TerminfoBased

import Blaze.ByteString.Builder (writeToByteString)
import Blaze.ByteString.Builder.Word (writeWord8)

import Control.Monad (void, when)
import Control.Monad.Trans
import Data.IORef

import System.Posix.IO (fdWrite)
import System.Posix.Types (Fd)

#if !(MIN_VERSION_base(4,8,0))
import Control.Applicative
import Data.Foldable (foldMap)
#endif

-- | Initialize the display to UTF-8. 
reserveTerminal :: ( Applicative m, MonadIO m ) => String -> Fd -> m Output
reserveTerminal variant outFd = liftIO $ do
    let flushedPut = void . fdWrite outFd
    -- If the terminal variant is xterm-color use xterm instead since, more often than not,
    -- xterm-color is broken.
    let variant' = if variant == "xterm-color" then "xterm" else variant
    flushedPut setUtf8CharSet
    t <- TerminfoBased.reserveTerminal variant' outFd

    mouseModeStatus <- newIORef False
    pasteModeStatus <- newIORef False

    let xtermSetMode t' m newStatus = do
          curStatus <- getModeStatus t' m
          when (newStatus /= curStatus) $
              case m of
                  Mouse -> liftIO $ do
                      case newStatus of
                          True -> flushedPut requestMouseEvents
                          False -> flushedPut disableMouseEvents
                      writeIORef mouseModeStatus newStatus
                  BracketedPaste -> liftIO $ do
                      case newStatus of
                          True -> flushedPut enableBracketedPastes
                          False -> flushedPut disableBracketedPastes
                      writeIORef pasteModeStatus newStatus

        xtermGetMode Mouse = liftIO $ readIORef mouseModeStatus
        xtermGetMode BracketedPaste = liftIO $ readIORef pasteModeStatus

    let t' = t
             { terminalID = terminalID t ++ " (xterm-color)"
             , releaseTerminal = do
                 liftIO $ flushedPut setDefaultCharSet
                 setMode t' BracketedPaste False
                 setMode t' Mouse False
                 releaseTerminal t
             , mkDisplayContext = \tActual r -> do
                dc <- mkDisplayContext t tActual r
                return $ dc { inlineHack = xtermInlineHack t' }
             , supportsMode = const True
             , getModeStatus = xtermGetMode
             , setMode = xtermSetMode t'
             }
    return t'

-- | Enable bracketed paste mode:
-- http://cirw.in/blog/bracketed-paste
enableBracketedPastes :: String
enableBracketedPastes = "\ESC[?2004h"

-- | Disable bracketed paste mode:
disableBracketedPastes :: String
disableBracketedPastes = "\ESC[?2004l"

-- | These sequences set xterm based terminals to UTF-8 output.
--
-- \todo I don't know of a terminfo cap that is equivalent to this.
setUtf8CharSet, setDefaultCharSet :: String
setUtf8CharSet = "\ESC%G"
setDefaultCharSet = "\ESC%@"

-- | I think xterm is broken: Reseting the background color as the first bytes serialized on a
-- new line does not effect the background color xterm uses to clear the line. Which is used
-- *after* the next newline.
xtermInlineHack :: Output -> IO ()
xtermInlineHack t = do
    let writeReset = foldMap (writeWord8.toEnum.fromEnum) "\ESC[K"
    outputByteBuffer t $ writeToByteString writeReset
