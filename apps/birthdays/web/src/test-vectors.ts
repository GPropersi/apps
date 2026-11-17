// Loads the shared Go/TypeScript fixture apps/birthdays/testdata/date-vectors.json for the tests. import.meta.glob keeps
// `tsc` (npm run build) working in the Docker `web` stage, where the file is not copied; only the `web-test` stage
// copies it, and a missing file there fails the tests loudly.
export type Vectors = {
  occurrence: { month: number; day: number; from: string; want: string }[];
  daysUntil: { from: string; to: string; want: number }[];
  turning: { year: number | null; occurrence: string; want: number | null }[];
  validDate: { month: number; day: number; year: number | null; want: boolean }[];
  tintIndex: { name: string; want: number }[];
};

const files = import.meta.glob("../../testdata/date-vectors.json", { eager: true, import: "default" });

export function loadVectors(): Vectors {
  const found = Object.values(files)[0];
  if (found === undefined) {
    throw new Error("testdata/date-vectors.json is missing: the Dockerfile web-test stage must COPY it to /src/testdata");
  }
  return found as Vectors;
}
