# librecode Campaign Demo

This demo executes a real multi-agent coordination campaign end-to-end using the Metaharness (`librecode-meta`) supervising a real child subprocess harness (`librecode-runner` running `run-child` in SBCL). The agent uses local Ollama and real tools (`write_file` and `bash`) to generate a gated artifact.

## Prerequisites

1. **Ollama**: Ensure Ollama is installed and running on your system.
   - For installation instructions, see [Ollama.com](https://ollama.com).
2. **Qwen 2.5 Coder 3B**: Pull the default coding model:
   ```bash
   ollama pull qwen2.5-coder:3b
   ```

## Running the Demo

To run the demo with the default model (`qwen2.5-coder:3b`) and default URL (`http://localhost:11434/v1`):

```bash
just demo
```

### Configuration

You can customize the model and the base URL by specifying environment variables:

```bash
OLLAMA_BASE_URL="http://localhost:11434/v1" OLLAMA_MODEL="qwen2.5-coder:3b" just demo
```

Or pass them as parameters to `just`:

```bash
just demo qwen2.5-coder:3b http://localhost:11434/v1
```

## How It Works

1. **Prerequisite Verification**: The demo checks that Ollama is reachable and that the configured model is pulled. If not, it self-documents the missing requirements and exits gracefully.
2. **Repository Setup**: A sandbox git repository is initialized.
3. **Campaign Dispatch**: A Kahn campaign DAG consisting of a single node (`demo-node`) is constructed.
4. **Subprocess Supervision**: The Metaharness spawns a `librecode-runner.child:run-child` process in a separate OS process, passing the configuration and initial instructions.
5. **Tool Execution**: The child agent executes `write_file` to write the gated artifact `proof.txt` and uses the `bash` tool to commit the file to git.
6. **Gate Validation**: The Metaharness runs a validation gate to ensure that `proof.txt` was created successfully with the correct content.
