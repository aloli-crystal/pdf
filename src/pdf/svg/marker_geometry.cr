module PDF
  module SVG
    # Sommets d'un tracé et direction en chacun d'eux, pour placer les
    # `marker` (SVG 1.1 § 11.6). Les directions sont en unités
    # utilisateur SVG (axe y vers le bas).
    module MarkerGeometry
      alias Vector = Tuple(Float64, Float64)

      # Un sommet, avec la direction du segment qui y arrive (`in`) et
      # de celui qui en part (`out`) ; nil en bout de tracé.
      record Vertex, x : Float64, y : Float64, in_dir : Vector?, out_dir : Vector? do
        # Angle (degrés) du marqueur : bissectrice des deux directions
        # en un sommet intermédiaire, sinon la seule connue.
        def angle : Float64
          a = in_dir.try { |d| MarkerGeometry.normalize(d) }
          b = out_dir.try { |d| MarkerGeometry.normalize(d) }
          dir = if a && b
                  sum = {a[0] + b[0], a[1] + b[1]}
                  # Demi-tour : la bissectrice est indéterminée.
                  sum[0].abs < 1e-9 && sum[1].abs < 1e-9 ? a : sum
                else
                  a || b
                end
          dir ? Math.atan2(dir[1], dir[0]) * 180.0 / Math::PI : 0.0
        end
      end

      # Sommets des commandes absolues de `PathParser` (M, L, C, Z).
      # Pour une courbe, la tangente vient des points de contrôle ;
      # un point de contrôle confondu avec l'extrémité est sauté.
      def self.vertices(commands : Array(PathCommand)) : Array(Vertex)
        vertices = [] of Vertex
        current = {0.0, 0.0}
        start = {0.0, 0.0}
        commands.each do |cmd|
          a = cmd.args
          case cmd.type
          when 'M'
            current = start = {a[0], a[1]}
            vertices << Vertex.new(a[0], a[1], nil, nil)
          when 'L'
            target = {a[0], a[1]}
            dir = direction(current, target)
            link(vertices, dir, dir, target)
            current = target
          when 'C'
            target = {a[4], a[5]}
            out_dir = direction(current, {a[0], a[1]}, {a[2], a[3]}, target)
            in_dir = direction({a[2], a[3]}, target) ||
                     direction({a[0], a[1]}, target) || direction(current, target)
            link(vertices, out_dir, in_dir, target)
            current = target
          when 'Z'
            dir = direction(current, start) || vertices.last?.try(&.in_dir)
            link(vertices, dir, dir, start)
            current = start
          end
        end
        vertices
      end

      # Ajoute le sommet `target`, atteint depuis le dernier sommet.
      private def self.link(vertices : Array(Vertex), out_dir : Vector?, in_dir : Vector?, target : Vector) : Nil
        if last = vertices.last?
          vertices[-1] = last.copy_with(out_dir: out_dir) if out_dir
        end
        vertices << Vertex.new(target[0], target[1], in_dir, nil)
      end

      # Direction de `from` vers le premier des points suivants qui en
      # est distinct, ou nil.
      private def self.direction(from : Vector, *targets : Vector) : Vector?
        targets.each do |t|
          d = {t[0] - from[0], t[1] - from[1]}
          return d if d[0].abs > 1e-9 || d[1].abs > 1e-9
        end
        nil
      end

      def self.normalize(v : Vector) : Vector
        len = Math.sqrt(v[0] ** 2 + v[1] ** 2)
        len.zero? ? v : {v[0] / len, v[1] / len}
      end
    end
  end
end
