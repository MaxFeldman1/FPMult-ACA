#include <iostream>
#include <iomanip>
#include <stdfloat>
#include <random>
#include <bit>
#include <cmath>

using bf16 = std::bfloat16_t;

uint16_t to_hex(bf16 value) {
    return std::bit_cast<uint16_t>(value);
}

int main() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint16_t> dis(0x0000, 0xFFFF);

    for (int i = 0; i < 20; ++i) {
        bf16 a = std::bit_cast<bf16>(dis(gen));
        bf16 b = std::bit_cast<bf16>(dis(gen));
        bf16 result = a * b;

        // --- Calculate Flags (OOR) ---
        uint8_t oor = 0;
        float res_f = static_cast<float>(result);
        
        if (res_f == 0.0f)           oor |= (1 << 3); // Zero flag
        if (std::isinf(res_f))       oor |= (1 << 2); // Infinity flag
        if (std::isnan(res_f))       oor |= (1 << 1); // NaN flag
        
        // Subnormal check: non-zero but absolute value less than smallest normal
        // Smallest normal for bfloat16 is 2^-126 (~1.17e-38)
        if (res_f != 0.0f && std::abs(res_f) < 1.17549435e-38f) {
            oor |= (1 << 0); 
        }

        // --- Pack the Line (54 bits) ---
        // Bit Mapping:
        // [53:52] round_mode (2'b00)
        // [51:36] test_x (a)
        // [35:20] test_y (b)
        // [19:4]  test_p (result)
        // [3:0]   oor
        
        uint64_t round_mode = 0x0; // 2'b00
        uint64_t packed_line = 0;
        
        packed_line |= (round_mode << 52);
        packed_line |= (static_cast<uint64_t>(to_hex(a)) << 36);
        packed_line |= (static_cast<uint64_t>(to_hex(b)) << 20);
        packed_line |= (static_cast<uint64_t>(to_hex(result)) << 4);
        packed_line |= (oor & 0xF);

        // Print as hex for the $fscanf %x
        std::cout << std::hex << std::setfill('0') << std::setw(14) << packed_line << std::endl;
    }

    return 0;
}
