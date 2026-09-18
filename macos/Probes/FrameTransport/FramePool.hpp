#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace vivid::probe {

struct Token {
    uint64_t generation;
    uint64_t sequence;
    uint64_t slot;
};

// A single serial queue owns this state. Completion makes a frame Ready;
// only a matching release from its reader makes the slot reusable.
class FramePool {
  public:
    static constexpr size_t size = 3;

    bool configure(uint64_t generation) {
        if (generation <= generation_ || !idle())
            return false;
        generation_ = generation;
        return true;
    }

    std::optional<Token> acquire() {
        if (!generation_ || sequence_ == std::numeric_limits<uint64_t>::max())
            return {};
        for (size_t i = 0; i < size; ++i) {
            if (slots_[i].state != State::Free)
                continue;
            slots_[i] = {State::Writing, ++sequence_};
            return Token{generation_, sequence_, i};
        }
        return {};
    }

    bool ready(Token token) { return transition(token, State::Writing, State::Ready); }
    bool release(Token token) { return transition(token, State::Ready, State::Free); }
    uint64_t generation() const { return generation_; }
    bool idle() const {
        for (const auto& slot : slots_)
            if (slot.state != State::Free)
                return false;
        return true;
    }

  private:
    enum class State { Free, Writing, Ready };
    struct Slot {
        State state = State::Free;
        uint64_t sequence = 0;
    };
    std::array<Slot, size> slots_{};
    uint64_t generation_ = 0;
    uint64_t sequence_ = 0;

    bool transition(Token token, State from, State to) {
        if (token.generation != generation_ || token.slot >= size)
            return false;
        auto& slot = slots_[token.slot];
        if (slot.sequence != token.sequence || slot.state != from)
            return false;
        slot.state = to;
        return true;
    }
};

} // namespace vivid::probe
