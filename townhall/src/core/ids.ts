import { randomBytes } from "node:crypto";
import type { Clock } from "./clock.js";

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export type IdPrefix = "agt" | "tl" | "tsk" | "apv" | "inc" | "pty" | "evt" | "rule";

/** Time-sortable ULID-style ids: `<prefix>_<10 time chars><16 random chars>`. */
export class Ids {
  private lastTime = -1;
  private lastRandom: number[] = [];

  constructor(private readonly clock: Clock) {}

  next(prefix: IdPrefix): string {
    return `${prefix}_${this.ulid()}`;
  }

  private ulid(): string {
    let time = this.clock.now();
    let rand: number[];
    if (time <= this.lastTime) {
      // Same millisecond (or clock went back): increment the random part to stay sortable.
      time = this.lastTime;
      rand = this.lastRandom.slice();
      for (let i = rand.length - 1; i >= 0; i--) {
        if (rand[i]! < 31) {
          rand[i]! += 1;
          break;
        }
        rand[i] = 0;
      }
    } else {
      const bytes = randomBytes(16);
      rand = Array.from(bytes, (b) => b & 31);
    }
    this.lastTime = time;
    this.lastRandom = rand;
    let timePart = "";
    let t = time;
    for (let i = 0; i < 10; i++) {
      timePart = CROCKFORD[t % 32] + timePart;
      t = Math.floor(t / 32);
    }
    return timePart + rand.map((n) => CROCKFORD[n]).join("");
  }
}

export function shortRandom(length = 8): string {
  const bytes = randomBytes(length);
  return Array.from(bytes, (b) => CROCKFORD[b & 31]).join("").toLowerCase();
}
