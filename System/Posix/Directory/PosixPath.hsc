{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE NondecreasingIndentation #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  System.Posix.Directory.PosixPath
-- Copyright   :  (c) The University of Glasgow 2002
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  provisional
-- Portability :  non-portable (requires POSIX)
--
-- PosixPath based POSIX directory support
--
-----------------------------------------------------------------------------

#include "HsUnix.h"

-- hack copied from System.Posix.Files
#if !defined(PATH_MAX)
# define PATH_MAX 4096
#endif

module System.Posix.Directory.PosixPath (
   -- * Creating and removing directories
   createDirectory, removeDirectory,

   -- * Reading directories
   DirStream,
   openDirStream,
   readDirStream,
   rewindDirStream,
   closeDirStream,
   DirStreamOffset,
#ifdef HAVE_TELLDIR
   tellDirStream,
#endif
#ifdef HAVE_SEEKDIR
   seekDirStream,
#endif

   -- * The working directory
   getWorkingDirectory,
   changeWorkingDirectory,
   changeWorkingDirectoryFd,
  ) where

import System.IO.Error
import System.Posix.Types
import Foreign
import Foreign.C

import System.OsPath.Types
import GHC.IO.Encoding.UTF8 ( mkUTF8 )
import GHC.IO.Encoding.Failure ( CodingFailureMode(..) )
import System.OsPath.Posix
import System.Posix.Directory hiding (createDirectory, openDirStream, readDirStream, getWorkingDirectory, changeWorkingDirectory, removeDirectory)
import qualified System.Posix.Directory.Common as Common
import System.Posix.PosixPath.FilePath

-- | @createDirectory dir mode@ calls @mkdir@ to
--   create a new directory, @dir@, with permissions based on
--  @mode@.
createDirectory :: PosixPath -> FileMode -> IO ()
createDirectory name mode =
  withFilePath name $ \s ->
    throwErrnoPathIfMinus1Retry_ "createDirectory" name (c_mkdir s mode)
    -- POSIX doesn't allow mkdir() to return EINTR, but it does on
    -- OS X (#5184), so we need the Retry variant here.

foreign import ccall unsafe "mkdir"
  c_mkdir :: CString -> CMode -> IO CInt

-- | @openDirStream dir@ calls @opendir@ to obtain a
--   directory stream for @dir@.
openDirStream :: PosixPath -> IO DirStream
openDirStream name =
  withFilePath name $ \s -> do
    dirp <- throwErrnoPathIfNullRetry "openDirStream" name $ c_opendir s
    return (Common.DirStream dirp)

foreign import capi unsafe "HsUnix.h opendir"
   c_opendir :: CString  -> IO (Ptr Common.CDir)

-- | @readDirStream dp@ calls @readdir@ to obtain the
--   next directory entry (@struct dirent@) for the open directory
--   stream @dp@, and returns the @d_name@ member of that
--  structure.
readDirStream :: DirStream -> IO PosixPath
readDirStream (Common.DirStream dirp) = alloca $ \ptr_dEnt  -> loop ptr_dEnt
 where
  loop ptr_dEnt = do
    resetErrno
    r <- c_readdir dirp ptr_dEnt
    if (r == 0)
         then do dEnt <- peek ptr_dEnt
                 if (dEnt == nullPtr)
                    then return mempty
                    else do
                     entry <- (d_name dEnt >>= peekFilePath)
                     c_freeDirEnt dEnt
                     return entry
         else do errno <- getErrno
                 if (errno == eINTR) then loop ptr_dEnt else do
                 let (Errno eo) = errno
                 if (eo == 0)
                    then return mempty
                    else throwErrno "readDirStream"

-- traversing directories
foreign import ccall unsafe "__hscore_readdir"
  c_readdir  :: Ptr Common.CDir -> Ptr (Ptr Common.CDirent) -> IO CInt

foreign import ccall unsafe "__hscore_free_dirent"
  c_freeDirEnt  :: Ptr Common.CDirent -> IO ()

foreign import ccall unsafe "__hscore_d_name"
  d_name :: Ptr Common.CDirent -> IO CString


-- | @getWorkingDirectory@ calls @getcwd@ to obtain the name
--   of the current working directory.
getWorkingDirectory :: IO PosixPath
getWorkingDirectory = go (#const PATH_MAX)
  where
    go bytes = do
        r <- allocaBytes bytes $ \buf -> do
            buf' <- c_getcwd buf (fromIntegral bytes)
            if buf' /= nullPtr
                then do s <- peekFilePath buf
                        return (Just s)
                else do errno <- getErrno
                        if errno == eRANGE
                            -- we use Nothing to indicate that we should
                            -- try again with a bigger buffer
                            then return Nothing
                            else throwErrno "getWorkingDirectory"
        maybe (go (2 * bytes)) return r

foreign import ccall unsafe "getcwd"
   c_getcwd   :: Ptr CChar -> CSize -> IO (Ptr CChar)

-- | @changeWorkingDirectory dir@ calls @chdir@ to change
--   the current working directory to @dir@.
changeWorkingDirectory :: PosixPath -> IO ()
changeWorkingDirectory path =
  modifyIOError (`ioeSetFileName` (_toStr path)) $
    withFilePath path $ \s ->
       throwErrnoIfMinus1Retry_ "changeWorkingDirectory" (c_chdir s)

foreign import ccall unsafe "chdir"
   c_chdir :: CString -> IO CInt

removeDirectory :: PosixPath -> IO ()
removeDirectory path =
  modifyIOError (`ioeSetFileName` _toStr path) $
    withFilePath path $ \s ->
       throwErrnoIfMinus1Retry_ "removeDirectory" (c_rmdir s)

foreign import ccall unsafe "rmdir"
   c_rmdir :: CString -> IO CInt

_toStr :: PosixPath -> String
_toStr fp = either (error . show) id $ decodeWith (mkUTF8 TransliterateCodingFailure) fp

