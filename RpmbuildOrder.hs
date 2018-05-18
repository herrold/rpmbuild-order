{-# LANGUAGE LambdaCase #-}

module Main where

import qualified Distribution.Verbosity as Verbosity
import qualified Distribution.ReadE as ReadE

import System.Console.GetOpt
          (getOpt, ArgOrder(..), OptDescr(..), ArgDescr(..), usageInfo, )
import System.Exit (exitSuccess, exitFailure, )
import qualified System.Environment as Env
import System.FilePath

import System.Directory (doesDirectoryExist)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcess)

import Data.Graph.Inductive.Query.DFS (topsort', scc, components, )
import Data.Graph.Inductive.Tree (Gr, )
import qualified Data.Graph.Inductive.Graph as Graph

import qualified Control.Monad.Exception.Synchronous as Exc
import qualified Control.Monad.Trans.Class as Trans

import qualified Data.Set as Set
import Control.Monad (guard, when, unless)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.List (delete, stripPrefix)

#if (defined(MIN_VERSION_base) && MIN_VERSION_base(4,8,2))
#else
import Control.Applicative ((<$>))
#endif

main :: IO ()
main =
   Exc.resolveT handleException $ do
      argv <- Trans.lift Env.getArgs
      let (opts, pkgs, errors) =
             getOpt RequireOrder options argv
      unless (null errors) $ Exc.throwT $ concat errors
      flags <-
         Exc.ExceptionalT $ return $
            foldr (=<<)
               (return
                Flags {optHelp = False,
                       optVerbosity = Verbosity.silent,
                       optInfo = name,
                       optParallel = False,
                       optBranch = Nothing})
               opts
      when (optHelp flags)
         (Trans.lift $
          Env.getProgName >>= \programName ->
          putStrLn
             (usageInfo ("Usage: " ++ programName ++
                         " [OPTIONS] PKG-SPEC-OR-DIR ...") options) >>
          exitSuccess)

      Trans.lift (mapM (findSpec (optBranch flags)) pkgs)
        >>= sortSpecFiles flags

handleException :: String -> IO ()
handleException msg = do
   putStrLn $ "Aborted: " ++ msg
   exitFailure

findSpec :: Maybe FilePath -> FilePath -> IO FilePath
findSpec mdir file =
  if takeExtension file == ".spec"
    then return file
    else do
    dirp <- doesDirectoryExist file
    if dirp
      then
      let dir = maybe file (file </>) mdir
          pkg = takeBaseName file in
        return $ dir </> pkg ++ ".spec"
      else error $ "Not spec file or directory: " ++ file

data Flags =
   Flags {
      optHelp :: Bool,
      optVerbosity :: Verbosity.Verbosity,
      optInfo :: SourcePackage -> String,
      optParallel :: Bool,
      optBranch :: Maybe FilePath
   }

options :: [OptDescr (Flags -> Exc.Exceptional String Flags)]
options =
  [
    Option ['h'] ["help"]
      (NoArg (\flags -> return $ flags{optHelp = True}))
      "show options"
  , Option ['v'] ["verbose"]
      (ReqArg
         (\str flags ->
            fmap (\n -> flags{optVerbosity = n}) $
            Exc.fromEither $
            ReadE.runReadE Verbosity.flagToVerbosity str)
         "N")
      "verbosity level: 0..3"
  , Option [] ["info"]
      (ReqArg
         (\str flags ->
            fmap (\select -> flags{optInfo = select}) $
            case str of
               "name" -> Exc.Success name
               "path" -> Exc.Success location
               "dir"  -> Exc.Success (takeDirectory . location)
               _ ->
                  Exc.Exception $
                  "unknown info type " ++ str)
         "KIND")
      "kind of output: name, path, dir"
  , Option ['p'] ["parallel"]
      (NoArg (\flags -> return $ flags{optParallel = True}))
      "Display independently buildable groups of packages"
  , Option ['b'] ["branch"]
      (ReqArg
         (\str flags ->
            fmap (\mb -> flags{optBranch = mb})
            (Exc.Success (Just str)))
         "BRANCHDIR")
    "branch directory"
  ]

data SourcePackage =
   SourcePackage {
      location :: FilePath,
      name :: String,
      dependencies :: [String]
   }
   deriving (Show, Eq)

sortSpecFiles :: Flags -> [FilePath] -> Exc.ExceptionalT String IO ()
sortSpecFiles flags specPaths = do
      let names = map takeBaseName specPaths
      provs <-
         Trans.lift $
         mapM (readProvides (optVerbosity flags)) specPaths
      let resolves = zip names provs
      deps <-
         Trans.lift $
         mapM (getDepsSrcResolved (optVerbosity flags) resolves) specPaths
      let pkgs = zipWith3 SourcePackage specPaths names deps
          graph = getBuildGraph pkgs
      checkForCycles graph
      Trans.lift $
         if optParallel flags
              then
                 mapM_ ((putStrLn . unwords . map (optInfo flags)) .
                         topsort' . subgraph graph)
                 (components graph)
              else
                 mapM_ (putStrLn . optInfo flags) $ topsort' graph
 
readProvides :: Verbosity.Verbosity -> FilePath -> IO [String]
readProvides verbose file = do
  when (verbose >= Verbosity.verbose) $ hPutStrLn stderr file
  pkgs <- lines <$>
    rpmspec ["--rpms", "--qf=%{name}\n", "--define", "ghc_version any"] Nothing file
  let name = takeBaseName file
  return $ delete name pkgs

readDependencies :: Verbosity.Verbosity -> FilePath -> IO [String]
readDependencies verbose file = do
  when (verbose >= Verbosity.verbose) $ hPutStrLn stderr file
  lines <$>
    rpmspec ["--buildrequires", "--define", "ghc_version any"] Nothing file

getDepsSrcResolved :: Verbosity.Verbosity -> [(String,[String])] -> FilePath -> IO [String]
getDepsSrcResolved verbose provides file =
  map (resolveBase provides) <$> readDependencies verbose file

resolveBase :: [(String,[String])] -> String -> String
resolveBase provs br =
  case mapMaybe (\ (pkg,subs) -> if br `elem` subs then Just pkg else Nothing) provs of
    [] -> br
    [p] -> p
    _ -> error $ "More than one package provides " ++ br

removeSuffix :: String -> String -> String
removeSuffix suffix orig =
  fromMaybe orig $ stripSuffix suffix orig
  where
    stripSuffix sf str = reverse <$> stripPrefix (reverse sf) (reverse str)


cmdStdIn :: String -> [String] -> String -> IO String
cmdStdIn c as inp = removeTrailingNewline <$> readProcess c as inp

removeTrailingNewline :: String -> String
removeTrailingNewline "" = ""
removeTrailingNewline str =
  if last str == '\n'
  then init str
  else str

cmd :: String -> [String] -> IO String
cmd c as = cmdStdIn c as ""

rpmspec :: [String] -> Maybe String -> FilePath -> IO String
rpmspec args mqf spec = do
  let qf = maybe [] (\ q -> ["--queryformat", q]) mqf
  cmd "rpmspec" (["-q"] ++ args ++ qf ++ [spec])

getDeps :: Gr SourcePackage () -> [(SourcePackage, [SourcePackage])]
getDeps gr =
    let c2dep :: Graph.Context SourcePackage () -> (SourcePackage, [SourcePackage])
        c2dep ctx =
           (Graph.lab' ctx,
            map (Graph.lab' . Graph.context gr) (Graph.pre gr . Graph.node' $ ctx))
    in  Graph.ufold (\ctx ds -> c2dep ctx : ds) [] gr

getBuildGraph ::
   [SourcePackage] ->
   Gr SourcePackage ()
getBuildGraph srcPkgs =
   let nodes = zip [0..] srcPkgs
       nodeDict =
          zip
             (map name srcPkgs)
             [0..]
       edges = do
          (srcNode,srcPkg) <- nodes
          dstNode <-
             mapMaybe (`lookup` nodeDict) (dependencies srcPkg)
          guard (dstNode /= srcNode)
          return (dstNode, srcNode, ())
   in  Graph.mkGraph nodes edges


checkForCycles ::
   Monad m =>
   Gr SourcePackage () ->
   Exc.ExceptionalT String m ()
checkForCycles graph =
   case getCycles graph of
      [] -> return ()
      cycles ->
         Exc.throwT $ unlines $
         "Cycles in dependencies:" :
         map (unwords . map location . nodeLabels graph) cycles

nodeLabels :: Gr a b -> [Graph.Node] -> [a]
nodeLabels graph =
   map (fromMaybe (error "node not found in graph") .
        Graph.lab graph)

subgraph :: Gr a b -> [Graph.Node] -> Gr a b
subgraph graph nodes =
   let nodeSet = Set.fromList nodes
       edges = do
           from <- nodes
           (to, lab) <- Graph.lsuc graph from
           guard $ Set.member from nodeSet && Set.member to nodeSet
           return (from,to,lab)
   in  Graph.mkGraph (zip nodes $ nodeLabels graph nodes) edges

getCycles :: Gr a b -> [[Graph.Node]]
getCycles =
   filter (\case
              _:_:_ -> True
              _ -> False)
   . scc
