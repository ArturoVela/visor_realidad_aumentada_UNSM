using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using UnityEngine;

namespace Nexus.Editor
{
    [DataContract]
    internal sealed class RoomCapture
    {
        [DataMember] public int schemaVersion;
        [DataMember] public string source;
        [DataMember] public string units;
        [DataMember] public string coordinateSystem;
        [DataMember] public string roomID;
        [DataMember] public string capturedAt;
        [DataMember] public RoomSurface[] surfaces;

        internal static RoomCapture Read(string path)
        {
            var file = new FileInfo(path);
            NexusRoomGeometry.Require(file.Length > 0 && file.Length <= 8 * 1024 * 1024, "JSON vacío o mayor de 8 MiB.");
            using (var stream = File.OpenRead(path))
                return (RoomCapture)new DataContractJsonSerializer(typeof(RoomCapture),
                    new DataContractJsonSerializerSettings { MaxItemsInObjectGraph = 100000 }).ReadObject(stream);
        }
    }

    [DataContract]
    internal sealed class RoomSurface
    {
        [DataMember] public string id;
        [DataMember] public string kind;
        [DataMember] public string confidence;
        [DataMember] public float[] dimensions;
        [DataMember] public float[] transformColumnMajor;
        [DataMember] public float[][] polygonCorners;
        [DataMember] public string parentID;
        [DataMember] public bool? doorIsOpen;
        [DataMember] public RoomCurve curve;

        internal Matrix4x4 Matrix
        {
            get
            {
                var matrix = new Matrix4x4();
                for (int i = 0; i < 16; i++) matrix[i % 4, i / 4] = transformColumnMajor[i];
                return matrix;
            }
        }
    }

    [DataContract]
    internal sealed class RoomCurve
    {
        [DataMember] public float[] center;
        [DataMember] public float radius;
        [DataMember] public double startAngleRadians;
        [DataMember] public double endAngleRadians;
    }

    internal sealed class RoomPiece
    {
        internal string Name;
        internal string Kind;
        internal Mesh Mesh;
    }

    internal static class NexusRoomGeometry
    {
        internal const float VisualWallThickness = 0.08f;
        const float Epsilon = 0.000001f;

        internal static Vector3 WorldPoint(Matrix4x4 roomMatrix, Vector3 localPoint)
        {
            // RoomPlan RH -> Unity LH. Transform raw local coordinates first, then reflect world Z.
            var point = roomMatrix.MultiplyPoint3x4(localPoint);
            return new Vector3(point.x, point.y, -point.z);
        }

        internal static void Validate(RoomCapture room)
        {
            Require(room != null && room.schemaVersion == 1, "Se requiere RoomStructure schemaVersion 1.");
            Require(room.units == "meters", "La captura debe usar metros.");
            Require(room.coordinateSystem == "RoomPlan native, right-handed, Y-up, session-local; no Unity conversion",
                "Sistema de coordenadas no admitido; no se aplicará una conversión supuesta.");
            Require(room.surfaces != null && room.surfaces.Length > 0 && room.surfaces.Length <= 512,
                "Cantidad de superficies vacía o excesiva.");
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var surface in room.surfaces)
            {
                Require(surface != null && !string.IsNullOrWhiteSpace(surface.id) && ids.Add(surface.id), "Identificador de superficie ausente o duplicado.");
                Require(new[] { "wall", "floor", "window", "door", "opening" }.Contains(surface.kind), "Tipo de superficie no admitido: " + surface.kind);
                Require(surface.curve == null, "Superficie curva no soportada todavía: " + surface.id);
                Require(surface.dimensions != null && surface.dimensions.Length == 3 && surface.dimensions.All(Finite)
                    && surface.dimensions[0] > 0 && surface.dimensions[1] > 0 && surface.dimensions[2] >= 0
                    && surface.dimensions[0] <= 100 && surface.dimensions[1] <= 100 && surface.dimensions[2] <= 0.005f,
                    "Se requiere superficie plana, ancho/alto positivos y de hasta 100 m: " + surface.id);
                var values = surface.transformColumnMajor;
                Require(values != null && values.Length == 16 && values.All(Finite), "Matriz inválida: " + surface.id);
                Require(Mathf.Abs(values[12]) <= 1000 && Mathf.Abs(values[13]) <= 1000 && Mathf.Abs(values[14]) <= 1000,
                    "Traslación fuera del límite de 1000 m de sesión: " + surface.id);
                Require(Mathf.Abs(values[3]) < 0.0001f && Mathf.Abs(values[7]) < 0.0001f
                    && Mathf.Abs(values[11]) < 0.0001f && Mathf.Abs(values[15] - 1) < 0.0001f, "Matriz no afín: " + surface.id);
                var matrix = surface.Matrix;
                Vector3 x = matrix.GetColumn(0), y = matrix.GetColumn(1), z = matrix.GetColumn(2);
                Require(Mathf.Abs(x.sqrMagnitude - 1) < 0.01f && Mathf.Abs(y.sqrMagnitude - 1) < 0.01f
                    && Mathf.Abs(z.sqrMagnitude - 1) < 0.01f && Mathf.Abs(Vector3.Dot(x, y)) < 0.01f
                    && Mathf.Abs(Vector3.Dot(x, z)) < 0.01f && Mathf.Abs(Vector3.Dot(y, z)) < 0.01f
                    && matrix.determinant > 0.99f, "Matriz con escala, reflexión o ejes no ortogonales: " + surface.id);
                Require(surface.polygonCorners != null && surface.polygonCorners.Length <= 512
                    && surface.polygonCorners.All(p => p != null && p.Length == 3 && p.All(Finite)
                        && Mathf.Abs(p[0]) <= 1000 && Mathf.Abs(p[1]) <= 1000 && Mathf.Abs(p[2]) <= 0.005f),
                    "Polígono no plano o inválido: " + surface.id);
                if (surface.kind == "floor")
                {
                    Require(Mathf.Abs(Vector3.Dot(z, Vector3.up)) > 0.99f, "Suelo inclinado no soportado: " + surface.id);
                    Triangulate(Polygon(surface));
                }
                else
                {
                    Require(Vector3.Dot(y, Vector3.up) > 0.99f, "Superficie vertical inclinada no soportada: " + surface.id);
                    Require(surface.polygonCorners.Length == 0, "Contorno vertical no rectangular no soportado: " + surface.id);
                }
            }
            Require(room.surfaces.Any(s => s.kind == "wall") && room.surfaces.Any(s => s.kind == "floor"), "La vista requiere al menos una pared y un suelo con contorno.");
            foreach (var hole in room.surfaces.Where(IsHole))
            {
                var wall = room.surfaces.FirstOrDefault(s => s.kind == "wall" && string.Equals(s.id, hole.parentID, StringComparison.OrdinalIgnoreCase));
                Require(wall != null, "Abertura sin pared padre válida: " + hole.id);
                HoleRectangle(wall, hole);
            }
            foreach (var wall in room.surfaces.Where(s => s.kind == "wall"))
                Require(room.surfaces.Count(s => IsHole(s) && string.Equals(s.parentID, wall.id, StringComparison.OrdinalIgnoreCase)) <= 32,
                    "Más de 32 aberturas en una pared: importación cancelada para limitar coste geométrico.");
        }

        internal static List<RoomPiece> Build(RoomCapture room, float thickness = VisualWallThickness)
        {
            Validate(room);
            Require(Finite(thickness) && thickness > 0 && thickness <= 1, "Espesor visual fuera de rango (0, 1] m.");
            var pieces = new List<RoomPiece>();
            foreach (var surface in room.surfaces)
            {
                if (surface.kind == "floor")
                    pieces.Add(new RoomPiece { Name = "Suelo " + surface.id, Kind = "floor", Mesh = FloorMesh(surface) });
                if (surface.kind != "wall") continue;
                var holes = room.surfaces.Where(s => IsHole(s) && string.Equals(s.parentID, surface.id, StringComparison.OrdinalIgnoreCase))
                    .Select(s => HoleRectangle(surface, s)).ToList();
                int index = 0;
                foreach (var cell in WallCells(surface.dimensions[0], surface.dimensions[1], holes))
                    pieces.Add(new RoomPiece { Name = "Muro " + surface.id + " segmento " + ++index, Kind = "wall", Mesh = WallBox(surface.Matrix, cell, thickness) });
            }
            return pieces;
        }

        internal static bool IsHole(RoomSurface surface) => surface.kind == "window" || surface.kind == "door" || surface.kind == "opening";
        internal static List<Vector2> Polygon(RoomSurface floor) => floor.polygonCorners.Select(p => new Vector2(p[0], p[1])).ToList();

        internal static Rect HoleRectangle(RoomSurface wall, RoomSurface hole)
        {
            var relative = wall.Matrix.inverse * hole.Matrix;
            Vector3 x = relative.GetColumn(0), y = relative.GetColumn(1);
            Require(Mathf.Abs(Mathf.Abs(x.x) - 1) < 0.01f && Mathf.Abs(Mathf.Abs(y.y) - 1) < 0.01f
                && Mathf.Abs(relative.m23) <= 0.03f, "Abertura no coplanaria o no alineada con su pared: " + hole.id);
            var a = relative.MultiplyPoint3x4(new Vector3(-hole.dimensions[0] / 2, -hole.dimensions[1] / 2, 0));
            var b = relative.MultiplyPoint3x4(new Vector3(hole.dimensions[0] / 2, hole.dimensions[1] / 2, 0));
            float halfWidth = wall.dimensions[0] / 2, halfHeight = wall.dimensions[1] / 2;
            float minX = Mathf.Min(a.x, b.x), maxX = Mathf.Max(a.x, b.x), minY = Mathf.Min(a.y, b.y), maxY = Mathf.Max(a.y, b.y);
            Require(minX >= -halfWidth - 0.03f && maxX <= halfWidth + 0.03f && minY >= -halfHeight - 0.03f
                && maxY <= halfHeight + 0.03f, "Abertura fuera de los límites de su pared: " + hole.id);
            return Rect.MinMaxRect(Mathf.Max(minX, -halfWidth), Mathf.Max(minY, -halfHeight), Mathf.Min(maxX, halfWidth), Mathf.Min(maxY, halfHeight));
        }

        internal static List<Rect> WallCells(float width, float height, List<Rect> holes)
        {
            // ponytail: rectangular aligned holes only; polygonal/curved apertures need polygon clipping.
            var xs = new SortedSet<float> { -width / 2, width / 2 };
            var ys = new SortedSet<float> { -height / 2, height / 2 };
            foreach (var hole in holes) { xs.Add(hole.xMin); xs.Add(hole.xMax); ys.Add(hole.yMin); ys.Add(hole.yMax); }
            var x = xs.ToArray(); var y = ys.ToArray(); var cells = new List<Rect>();
            for (int i = 0; i < x.Length - 1; i++)
                for (int j = 0; j < y.Length - 1; j++)
                {
                    var cell = Rect.MinMaxRect(x[i], y[j], x[i + 1], y[j + 1]);
                    if (cell.width > Epsilon && cell.height > Epsilon && !holes.Any(h => h.Contains(cell.center))) cells.Add(cell);
                }
            return cells;
        }

        internal static Mesh FloorMesh(RoomSurface floor)
        {
            var vertices = floor.polygonCorners.Select(p => WorldPoint(floor.Matrix, new Vector3(p[0], p[1], p[2]))).ToArray();
            var triangles = Triangulate(Polygon(floor));
            for (int i = 0; i < triangles.Length; i += 3)
                if (Vector3.Cross(vertices[triangles[i + 1]] - vertices[triangles[i]], vertices[triangles[i + 2]] - vertices[triangles[i]]).y < 0)
                    (triangles[i + 1], triangles[i + 2]) = (triangles[i + 2], triangles[i + 1]);
            var mesh = new Mesh { name = "Suelo cóncavo", vertices = vertices, triangles = triangles };
            mesh.RecalculateNormals(); mesh.RecalculateBounds();
            return mesh;
        }

        static Mesh WallBox(Matrix4x4 matrix, Rect rect, float depth)
        {
            var vertices = new List<Vector3>(); var triangles = new List<int>();
            var points = new[] {
                new Vector3(rect.xMin, rect.yMin, -depth / 2), new Vector3(rect.xMax, rect.yMin, -depth / 2),
                new Vector3(rect.xMax, rect.yMax, -depth / 2), new Vector3(rect.xMin, rect.yMax, -depth / 2),
                new Vector3(rect.xMin, rect.yMin, depth / 2), new Vector3(rect.xMax, rect.yMin, depth / 2),
                new Vector3(rect.xMax, rect.yMax, depth / 2), new Vector3(rect.xMin, rect.yMax, depth / 2) };
            var faces = new[] { new[] { 0, 3, 2, 1 }, new[] { 4, 5, 6, 7 }, new[] { 0, 4, 7, 3 },
                new[] { 1, 2, 6, 5 }, new[] { 0, 1, 5, 4 }, new[] { 3, 7, 6, 2 } };
            foreach (var face in faces)
            {
                int start = vertices.Count;
                vertices.AddRange(face.Select(i => WorldPoint(matrix, points[i])));
                // Reflection reverses handedness, so reverse each face's local winding.
                triangles.AddRange(new[] { start, start + 2, start + 1, start, start + 3, start + 2 });
            }
            var mesh = new Mesh { name = "Panel de muro (espesor visual)", vertices = vertices.ToArray(), triangles = triangles.ToArray() };
            mesh.RecalculateNormals(); mesh.RecalculateBounds();
            return mesh;
        }

        internal static float SignedArea(IReadOnlyList<Vector2> polygon)
        {
            double sum = 0;
            for (int i = 0; i < polygon.Count; i++) { var a = polygon[i]; var b = polygon[(i + 1) % polygon.Count]; sum += (double)a.x * b.y - (double)b.x * a.y; }
            return (float)(sum / 2);
        }

        internal static int[] Triangulate(IReadOnlyList<Vector2> polygon)
        {
            Require(polygon != null && polygon.Count >= 3 && polygon.Count <= 512, "El suelo requiere entre 3 y 512 esquinas.");
            for (int i = 0; i < polygon.Count; i++)
            {
                Require(Finite(polygon[i].x) && Finite(polygon[i].y), "Coordenada no finita en polígono.");
                for (int j = i + 1; j < polygon.Count; j++) Require((polygon[i] - polygon[j]).sqrMagnitude > Epsilon * Epsilon, "Polígono con vértices repetidos.");
                for (int j = i + 1; j < polygon.Count; j++)
                {
                    int nextI = (i + 1) % polygon.Count, nextJ = (j + 1) % polygon.Count;
                    if (j == nextI || nextJ == i) continue;
                    Require(!Intersects(polygon[i], polygon[nextI], polygon[j], polygon[nextJ]), "Polígono autointersectado.");
                }
            }
            float area = SignedArea(polygon);
            Require(Mathf.Abs(area) > Epsilon, "Polígono de área nula.");
            var remaining = Enumerable.Range(0, polygon.Count).ToList();
            if (area < 0) remaining.Reverse();
            var result = new List<int>();
            // ponytail: bounded ear clipping (<=512 corners); use a tessellator if larger contours become necessary.
            while (remaining.Count > 3)
            {
                bool found = false;
                for (int i = 0; i < remaining.Count; i++)
                {
                    int a = remaining[(i + remaining.Count - 1) % remaining.Count], b = remaining[i], c = remaining[(i + 1) % remaining.Count];
                    if (Cross(polygon[b] - polygon[a], polygon[c] - polygon[b]) <= Epsilon) continue;
                    if (remaining.Any(p => p != a && p != b && p != c && InTriangle(polygon[p], polygon[a], polygon[b], polygon[c]))) continue;
                    result.AddRange(new[] { a, b, c }); remaining.RemoveAt(i); found = true; break;
                }
                Require(found, "No se puede triangular el contorno; revise vértices degenerados o autointersecciones.");
            }
            Require(Cross(polygon[remaining[1]] - polygon[remaining[0]], polygon[remaining[2]] - polygon[remaining[0]]) > Epsilon, "Triángulo final degenerado.");
            result.AddRange(remaining);
            return result.ToArray();
        }

        static bool Intersects(Vector2 a, Vector2 b, Vector2 c, Vector2 d)
        {
            float abC = Cross(b - a, c - a), abD = Cross(b - a, d - a), cdA = Cross(d - c, a - c), cdB = Cross(d - c, b - c);
            if (((abC > Epsilon && abD < -Epsilon) || (abC < -Epsilon && abD > Epsilon))
                && ((cdA > Epsilon && cdB < -Epsilon) || (cdA < -Epsilon && cdB > Epsilon))) return true;
            return (Mathf.Abs(abC) <= Epsilon && OnSegment(a, b, c)) || (Mathf.Abs(abD) <= Epsilon && OnSegment(a, b, d))
                || (Mathf.Abs(cdA) <= Epsilon && OnSegment(c, d, a)) || (Mathf.Abs(cdB) <= Epsilon && OnSegment(c, d, b));
        }

        static bool OnSegment(Vector2 a, Vector2 b, Vector2 p) => p.x >= Mathf.Min(a.x, b.x) - Epsilon && p.x <= Mathf.Max(a.x, b.x) + Epsilon
            && p.y >= Mathf.Min(a.y, b.y) - Epsilon && p.y <= Mathf.Max(a.y, b.y) + Epsilon;
        static bool InTriangle(Vector2 p, Vector2 a, Vector2 b, Vector2 c) => Cross(b - a, p - a) >= -Epsilon && Cross(c - b, p - b) >= -Epsilon && Cross(a - c, p - c) >= -Epsilon;
        static float Cross(Vector2 a, Vector2 b) => a.x * b.y - a.y * b.x;
        static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        internal static void Require(bool condition, string message) { if (!condition) throw new InvalidDataException(message); }
    }
}
