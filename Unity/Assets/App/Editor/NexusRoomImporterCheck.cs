using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Serialization.Json;
using UnityEngine;

namespace Nexus.Editor
{
    internal static class NexusRoomImporterCheck
    {
        internal static void Run()
        {
            var matrix = Matrix4x4.TRS(new Vector3(1, 2, 3), Quaternion.Euler(0, 90, 0), Vector3.one);
            Check(Vector3.Distance(NexusRoomGeometry.WorldPoint(matrix, Vector3.right), new Vector3(1, 2, -2)) < 0.00001f,
                "Conversión column-major y reflexión Z.");

            // Synthetic nine-corner concave contour; no private capture geometry is committed here.
            float scale = 12.218f / 14.5f;
            var polygon = new[] { new Vector2(0, 0), new Vector2(4, 0), new Vector2(4, 1), new Vector2(3, 1),
                new Vector2(3, 2), new Vector2(4, 2), new Vector2(4, 4), new Vector2(1, 4), new Vector2(0, 3) }
                .Select(p => new Vector2(p.x * scale, p.y)).ToArray();
            var floor = Surface("floor", 4, 4, Matrix4x4.Rotate(Quaternion.Euler(90, 0, 0)));
            floor.polygonCorners = polygon.Select(p => new[] { p.x, p.y, 0f }).ToArray();
            var wall = Surface("wall", 4, 3, Matrix4x4.identity);
            var window = Surface("window", 1, 1, Matrix4x4.Translate(new Vector3(0, 0.5f, 0)));
            window.parentID = wall.id;
            var room = new RoomCapture { schemaVersion = 1, units = "meters", source = "Synthetic self-check", roomID = "synthetic",
                coordinateSystem = "RoomPlan native, right-handed, Y-up, session-local; no Unity conversion", capturedAt = "2026-01-01T00:00:00Z", surfaces = new[] { wall, window, floor } };
            NexusRoomGeometry.Validate(room);
            Check(Mathf.Abs(NexusRoomGeometry.SignedArea(polygon) - 12.218f) < 0.0001f, "Área sintética 12.218 m².");
            var mesh = NexusRoomGeometry.FloorMesh(floor);
            try
            {
                Check(mesh.triangles.Length == (polygon.Length - 2) * 3, "Suelo cóncavo debe producir siete triángulos.");
                float area = 0;
                for (int i = 0; i < mesh.triangles.Length; i += 3)
                {
                    var a = mesh.vertices[mesh.triangles[i]]; var b = mesh.vertices[mesh.triangles[i + 1]]; var c = mesh.vertices[mesh.triangles[i + 2]];
                    var cross = Vector3.Cross(b - a, c - a);
                    Check(cross.y > 0, "Winding del suelo debe mirar hacia arriba tras flip Z.");
                    area += cross.magnitude / 2;
                }
                Check(Mathf.Abs(area - 12.218f) < 0.0001f, "Triángulos deben conservar área cóncava.");
            }
            finally { UnityEngine.Object.DestroyImmediate(mesh); }
            var hole = NexusRoomGeometry.HoleRectangle(wall, window);
            var cells = NexusRoomGeometry.WallCells(4, 3, new List<Rect> { hole });
            Check(Mathf.Abs(cells.Sum(c => c.width * c.height) - 11) < 0.0001f, "Ventana debe restar 1 m² al muro de 12 m².");
            Check(!cells.Any(c => c.Contains(hole.center)), "Centro de ventana debe permanecer libre.");

            using (var stream = new MemoryStream())
            {
                var serializer = new DataContractJsonSerializer(typeof(RoomCapture));
                serializer.WriteObject(stream, room); stream.Position = 0;
                var copy = (RoomCapture)serializer.ReadObject(stream);
                Check(copy.capturedAt == room.capturedAt && copy.surfaces[2].polygonCorners.Length == 9, "JSON ISO como string y esquinas float[][].");
                NexusRoomGeometry.Validate(copy);
            }
            Reject(() => NexusRoomGeometry.Triangulate(new[] { Vector2.zero, Vector2.one, Vector2.up, Vector2.right }), "Polígono autointersectado.");
            Reject(() => NexusRoomGeometry.Triangulate(new[] { Vector2.zero, Vector2.right, Vector2.right }), "Vértices repetidos.");
            window.parentID = "missing";
            Reject(() => NexusRoomGeometry.Validate(room), "Abertura sin padre.");
            window.parentID = wall.id;
            wall.curve = new RoomCurve();
            Reject(() => NexusRoomGeometry.Validate(room), "Superficie curva no soportada.");
            wall.curve = null;
            wall.transformColumnMajor[0] = float.NaN;
            Reject(() => NexusRoomGeometry.Validate(room), "Matriz no finita.");
            Debug.Log("NEXUS_ROOM_IMPORTER_CHECK_OK: coordenadas, JSON, suelo cóncavo 12.218 m²/7 triángulos, normales, hueco de ventana y rechazo de geometría inválida.");
        }

        static RoomSurface Surface(string kind, float width, float height, Matrix4x4 matrix)
        {
            var values = new float[16];
            for (int i = 0; i < 16; i++) values[i] = matrix[i % 4, i / 4];
            return new RoomSurface { id = Guid.NewGuid().ToString(), kind = kind, confidence = "synthetic", dimensions = new[] { width, height, 0f },
                transformColumnMajor = values, polygonCorners = Array.Empty<float[]>() };
        }
        static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException("Self-check: " + message); }
        static void Reject(Action action, string message)
        {
            try { action(); }
            catch (InvalidDataException) { return; }
            throw new InvalidOperationException("Se aceptó geometría inválida: " + message);
        }
    }
}
