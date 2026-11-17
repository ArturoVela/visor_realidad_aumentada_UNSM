using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

namespace Nexus.Editor
{
    public static class NexusRoomImporter
    {
        [MenuItem("Nexus/Importar cuarto JSON...")]
        public static void ImportFromMenu()
        {
            string captures = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", "LocalCaptures"));
            string input = EditorUtility.OpenFilePanel("Importar estructura RoomPlan", Directory.Exists(captures) ? captures : "", "json");
            if (string.IsNullOrEmpty(input)) return;
            List<RoomPiece> pieces = null;
            try
            {
                EditorUtility.DisplayProgressBar("Cuarto virtual", "Validando captura y aberturas…", 0.2f);
                var capture = RoomCapture.Read(input);
                pieces = NexusRoomGeometry.Build(capture);
                EditorUtility.ClearProgressBar();
                if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
                {
                    foreach (var piece in pieces) UnityEngine.Object.DestroyImmediate(piece.Mesh);
                    return;
                }
                string folder = "Assets/LocalCaptures/RoomPreview_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + "_" + Guid.NewGuid().ToString("N").Substring(0, 6);
                SavePreview(capture, pieces, folder + "/RoomPreview.unity");
            }
            catch (Exception error)
            {
                Debug.LogException(error);
                EditorUtility.DisplayDialog("No se pudo importar el cuarto", error.Message, "Cerrar");
            }
            finally { EditorUtility.ClearProgressBar(); }
        }

        // Unity -batchmode -executeMethod Nexus.Editor.NexusRoomImporter.BuildFromCommandLine
        // -nexusRoomJson /absolute/room.json -nexusRoomScene Assets/LocalCaptures/check/RoomPreview.unity
        public static void BuildFromCommandLine()
        {
            var capture = RoomCapture.Read(Argument("-nexusRoomJson"));
            var pieces = NexusRoomGeometry.Build(capture);
            SavePreview(capture, pieces, Argument("-nexusRoomScene"));
        }

        [MenuItem("Nexus/Verificar importador")]
        public static void RunSelfCheck() => NexusRoomImporterCheck.Run();

        static string Argument(string name)
        {
            var args = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(args, name);
            if (index < 0 || index + 1 >= args.Length || args[index + 1].StartsWith("-", StringComparison.Ordinal))
                throw new ArgumentException("Falta argumento " + name);
            return args[index + 1];
        }

        static void SavePreview(RoomCapture capture, List<RoomPiece> pieces, string requestedPath)
        {
            string project = Path.GetDirectoryName(Application.dataPath);
            string absolute = Path.GetFullPath(Path.IsPathRooted(requestedPath) ? requestedPath : Path.Combine(project, requestedPath));
            string allowed = Path.GetFullPath(Path.Combine(Application.dataPath, "LocalCaptures")) + Path.DirectorySeparatorChar;
            NexusRoomGeometry.Require(absolute.StartsWith(allowed, StringComparison.Ordinal) && Path.GetExtension(absolute).Equals(".unity", StringComparison.OrdinalIgnoreCase),
                "La escena generada debe estar dentro de Assets/LocalCaptures/ y terminar en .unity.");
            string scenePath = "Assets/" + absolute.Substring(Application.dataPath.Length + 1).Replace('\\', '/');
            string geometryPath = Path.ChangeExtension(scenePath, ".asset");
            NexusRoomGeometry.Require(!File.Exists(absolute) && !File.Exists(Path.ChangeExtension(absolute, ".asset")), "El destino ya existe; elige una carpeta nueva para no sobrescribirlo.");
            var shader = Shader.Find("Universal Render Pipeline/Lit");
            NexusRoomGeometry.Require(shader != null, "No está disponible Universal Render Pipeline/Lit. Revisa URP antes de importar.");

            Directory.CreateDirectory(Path.GetDirectoryName(absolute));
            AssetDatabase.Refresh();
            var wallMaterial = new Material(shader) { name = "Muros — espesor visual no medido" };
            wallMaterial.SetColor("_BaseColor", new Color(0.76f, 0.8f, 0.83f));
            var floorMaterial = new Material(shader) { name = "Suelo capturado" };
            floorMaterial.SetColor("_BaseColor", new Color(0.22f, 0.3f, 0.37f));
            bool assetCreated = false;
            try
            {
                AssetDatabase.CreateAsset(pieces[0].Mesh, geometryPath);
                assetCreated = true;
                foreach (var piece in pieces.Skip(1)) AssetDatabase.AddObjectToAsset(piece.Mesh, geometryPath);
                AssetDatabase.AddObjectToAsset(wallMaterial, geometryPath);
                AssetDatabase.AddObjectToAsset(floorMaterial, geometryPath);
                AssetDatabase.SaveAssets();

                var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                var room = new GameObject("Cuarto capturado [metros 1:1 — medidas estimadas]");
                var walls = new GameObject("Muros [espesor visual 0.08 m — no medido]");
                walls.transform.SetParent(room.transform, false);
                var floor = new GameObject("Suelo [contorno capturado; sin completar perímetro]");
                floor.transform.SetParent(room.transform, false);
                Bounds bounds = pieces[0].Mesh.bounds;
                foreach (var piece in pieces)
                {
                    var item = new GameObject(piece.Name);
                    item.transform.SetParent(piece.Kind == "wall" ? walls.transform : floor.transform, false);
                    item.AddComponent<MeshFilter>().sharedMesh = piece.Mesh;
                    item.AddComponent<MeshRenderer>().sharedMaterial = piece.Kind == "wall" ? wallMaterial : floorMaterial;
                    item.AddComponent<MeshCollider>().sharedMesh = piece.Mesh;
                    bounds.Encapsulate(piece.Mesh.bounds);
                }
                var apertures = new GameObject("Aberturas [huecos libres; sin hojas inventadas]");
                apertures.transform.SetParent(room.transform, false);
                foreach (var surface in capture.surfaces.Where(NexusRoomGeometry.IsHole))
                {
                    var marker = new GameObject(surface.kind + " " + surface.id + " [hueco libre]");
                    marker.transform.SetParent(apertures.transform, false);
                    marker.transform.position = NexusRoomGeometry.WorldPoint(surface.Matrix, Vector3.zero);
                }
                AddView(bounds);
                Selection.activeGameObject = room;
                EditorSceneManager.MarkSceneDirty(scene);
                if (!EditorSceneManager.SaveScene(scene, scenePath)) throw new IOException("Unity no pudo guardar la escena generada.");
                if (!Application.isBatchMode && SceneView.lastActiveSceneView != null) SceneView.lastActiveSceneView.Frame(bounds, true);
                float area = capture.surfaces.Where(s => s.kind == "floor").Sum(s => Mathf.Abs(NexusRoomGeometry.SignedArea(NexusRoomGeometry.Polygon(s))));
                Debug.Log($"NEXUS_ROOM_IMPORTED {scenePath}: {capture.surfaces.Count(s => s.kind == "wall")} muros, " +
                    $"{capture.surfaces.Count(s => s.kind == "window")} ventanas, suelo {area:F3} m². " +
                    "Cuarto virtual sin mobiliario; calibración física pendiente. Espesor de muro visual: 0.08 m, no medido.");
                if (!capture.surfaces.Any(s => s.kind == "door"))
                    Debug.LogWarning("Sin puertas detectadas; revisar accesos y tramos abiertos. No se añadieron muros para cerrar el perímetro.");
            }
            catch
            {
                if (assetCreated) AssetDatabase.DeleteAsset(geometryPath);
                throw;
            }
        }

        static void AddView(Bounds bounds)
        {
            var camera = new GameObject("Vista inicial del cuarto").AddComponent<Camera>();
            camera.tag = "MainCamera";
            camera.orthographic = true;
            camera.orthographicSize = Mathf.Max(bounds.size.magnitude * 0.55f, 3);
            camera.nearClipPlane = 0.05f;
            camera.farClipPlane = Mathf.Max(100, bounds.size.magnitude * 10);
            camera.transform.position = bounds.center + new Vector3(-1.1f, 1.7f, -1.2f).normalized * Mathf.Max(bounds.size.magnitude * 2, 10);
            camera.transform.LookAt(bounds.center);
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.09f, 0.12f, 0.16f);
            var light = new GameObject("Luz de inspección").AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = 1.7f;
            light.transform.rotation = Quaternion.Euler(50, -30, 0);
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(0.55f, 0.6f, 0.65f);
        }
    }
}
