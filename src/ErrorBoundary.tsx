import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props {
  children: ReactNode
}
interface State {
  error: Error | null
}

/** Keeps a single broken panel from taking down the whole page. */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[xCorp]', error, info.componentStack)
  }

  render() {
    if (this.state.error) {
      return (
        <div className="mx-auto max-w-[1400px] px-5 py-10">
          <div className="border-2 border-ink">
            <div className="bg-ink px-3 py-1.5">
              <span className="ui ui-10 text-paper">Something Broke</span>
            </div>
            <div className="p-4">
              <p className="text-[12px] text-ink-mute">
                This view failed to render. The error has been logged to the console.
              </p>
              <pre className="mt-3 overflow-x-auto border border-rule bg-wash p-2 text-[11px]">
                {this.state.error.message}
              </pre>
              <button
                onClick={() => this.setState({ error: null })}
                className="ui ui-10 mt-3 bg-ink px-4 py-2 text-paper"
              >
                Retry
              </button>
            </div>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}
