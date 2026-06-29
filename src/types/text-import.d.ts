// Bun's bundler loads `.txt` imports as their string contents (and inlines
// them into the compiled binary). Declare the module shape so `tsc` is happy.
declare module '*.txt' {
  const content: string;
  export default content;
}
