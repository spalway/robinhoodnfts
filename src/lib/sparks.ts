// Ember emitter for the X-RATED badge.
//
// Pure state + step function, kept out of the component because
// requestAnimationFrame is paused whenever a page isn't being composited —
// which makes canvas animation impossible to verify in-browser. As a plain
// state machine it is unit-testable.

export interface Spark {
  x: number
  y: number
  vx: number
  vy: number
  /** Counts down to 0, then the spark respawns at the base. */
  life: number
  maxLife: number
}

/**
 * Deep red through to bright red, sampled by remaining life.
 *
 * Every stop is the same hue — only luminance moves. A previous ramp ran the
 * hot end through orange (#ff6a3d) into cream (#ffd08a), which is what a real
 * ember does but reads as multicoloured fire rather than as a laser. X-RATED is
 * meant to be one red, so brightness carries the heat instead of hue.
 */
export const SPARK_COLORS = ['#6b0202', '#9e0808', '#d01414', '#ff1b1b', '#ff4d4d'] as const

export function sparkColor(spark: Spark): string {
  const t = Math.max(0, Math.min(1, spark.life / spark.maxLife))
  // Hottest at birth, dimmest as it dies.
  const idx = Math.min(SPARK_COLORS.length - 1, Math.floor(t * SPARK_COLORS.length))
  return SPARK_COLORS[idx]
}

function respawn(spark: Spark, width: number, height: number, rand: () => number): void {
  spark.x = rand() * width
  spark.y = height - rand() * 2
  spark.vx = (rand() - 0.5) * 0.14
  spark.vy = -(0.12 + rand() * 0.22)
  spark.maxLife = 26 + Math.floor(rand() * 26)
  spark.life = spark.maxLife
}

/**
 * Ember density for a flame field spanning a label.
 *
 * Scaled to area rather than fixed, so a short badge and a long one burn at the
 * same visual intensity. Capped because this draws over live text — past ~70
 * the glyphs stop being readable, which defeats the point of a label.
 */
export function flameCount(width: number, height: number): number {
  return Math.max(10, Math.min(70, Math.round(width * height * 0.09)))
}

export function seedSparks(count: number, width: number, height: number, rand: () => number): Spark[] {
  const out: Spark[] = []
  for (let i = 0; i < count; i++) {
    const spark: Spark = { x: 0, y: 0, vx: 0, vy: 0, life: 0, maxLife: 1 }
    respawn(spark, width, height, rand)
    // Stagger initial life so they don't all pulse in unison.
    spark.life = Math.max(1, Math.floor(rand() * spark.maxLife))
    out.push(spark)
  }
  return out
}

/** Advance one frame. Sparks always respawn, so the emitter never runs dry. */
export function stepSparks(sparks: Spark[], width: number, height: number, rand: () => number): void {
  for (const spark of sparks) {
    spark.x += spark.vx
    spark.y += spark.vy
    spark.life -= 1
    if (spark.life <= 0 || spark.y < -1 || spark.x < -1 || spark.x > width + 1) {
      respawn(spark, width, height, rand)
    }
  }
}
