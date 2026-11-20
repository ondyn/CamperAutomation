/**
 * @file waste_valve_17hs4401_current_limits.h
 * @brief TMC2209 Current Configuration Helper for Simax 3D NEMA 17 17HS4401
 *
 * This header provides current limiting configuration for the MKS TMC2209 V2.0
 * driver paired with a Simax 3D NEMA 17 17HS4401 stepper motor.
 *
 * Motor Specs:
 *  - Holding torque: 42–43 N·cm @ 1.7 A peak per phase
 *  - Phase resistance: ~1.5–1.65 Ω per coil
 *  - Nominal voltage: 2.6 V DC @ 1.7 A (peak)
 *  - Recommended RMS: 0.8–1.0 A for camper application (power & heat budget)
 *
 * TMC2209 Current Configuration:
 *  - IRUN (running current): 5-bit register (0–31), linearly scaled to max
 *  - IHOLD (holding current): 5-bit register (0–31), linearly scaled to max
 *  - Default max current (with 0.11 Ω sense resistors): 2.0 A peak
 *  - Scaling: register_value = (desired_A / max_A) * 31
 *
 * UART Write Sequence (pseudocode from waste_valve_tmc2209.h):
 *  uint32_t ihold_irun = (ihold << 16) | (irun << 8);
 *  waste_valve::tmc2209::write_request(addr, IHOLD_IRUN_REG, ihold_irun, request);
 *  // Send 8-byte request over UART, read 8-byte reply
 */

#pragma once

#include <cstdint>

namespace waste_valve::current_config {

/**
 * @struct MotorCurrentLimits
 * @brief Current settings for 17HS4401 with TMC2209 V2.0 (0.11 Ω sense resistors)
 *
 * All currents are RMS (root-mean-square), suitable for long-term duty.
 * Peak current = RMS * sqrt(2) ≈ RMS * 1.41, but TMC2209 controls RMS.
 */
struct MotorCurrentLimits {
  float run_current_rms;   ///< A RMS; typical 0.8–1.0 A for waste valve
  float hold_current_rms;  ///< A RMS; typical 0.2–0.4 A for low battery draw
};

/**
 * @struct TMC2209RegisterValues
 * @brief UART register values for IRUN and IHOLD (5-bit each, 0–31)
 *
 * Register mapping (IHOLD_IRUN address 0x10):
 *  Bits 31–20:  Reserved
 *  Bits 19–16:  IHOLD (4 bits, effective range 0–15 on some variants)
 *  Bits 15–8:   Reserved
 *  Bits 7–4:    IHOLD (extension, check datasheet for your TMC variant)
 *  Bits 3–0:    IRUN (4 bits)
 *
 * Typical encoding (verify with your specific TMC2209 revision):
 *  uint32_t value = (IHOLD << 16) | (IRUN << 8);
 *
 * Current = (register_value / 31) * max_current_rating
 * For TMC2209 with 0.11 Ω sense: max_current ≈ 2.0 A
 */
struct TMC2209RegisterValues {
  uint8_t irun;   ///< Running current register (0–31)
  uint8_t ihold;  ///< Holding current register (0–31)
};

/**
 * calculate_irun_ihold()
 * @param run_rms_amps    Desired running current in amps RMS
 * @param hold_rms_amps   Desired holding current in amps RMS
 * @param sense_ohms      Sense resistor value (e.g., 0.11 for MKS V2.0)
 * @return TMC2209RegisterValues with IRUN and IHOLD for UART write
 *
 * Example:
 *  auto curr = calculate_irun_ihold(0.9, 0.3, 0.11);
 *  // curr.irun = 14, curr.ihold = 5 (approx)
 *
 * Formula (from Trinamic TMC2209 datasheet):
 *  I_out = I_scale * (I_sense + 1) / 32
 *  where I_scale ≈ register_value, I_sense = current_to_set / 2.0
 *
 * Simplified for this driver:
 *  register_value = (desired_RMS / 2.0) * 31
 *  where 2.0 A is the reference (100% = register 31)
 */
inline TMC2209RegisterValues calculate_irun_ihold(
    float run_rms_amps, float hold_rms_amps, float sense_ohms = 0.11f) {
  // TMC2209 with 0.11 Ω sense: max sustainable is ~2.0 A RMS
  constexpr float max_current_rms = 2.0f;
  constexpr uint8_t max_register = 31;

  // Scale current to 5-bit register (0–31)
  auto scale_to_register = [](float amps_rms) -> uint8_t {
    float scaled = (amps_rms / max_current_rms) * max_register;
    return static_cast<uint8_t>(scaled + 0.5f);  // Round to nearest int
  };

  return {
      .irun = scale_to_register(run_rms_amps),
      .ihold = scale_to_register(hold_rms_amps)
  };
}

/**
 * Predefined Current Profiles for 17HS4401
 */
namespace profiles_17hs4401 {

/** Standard: Reliable torque for infrequent operation */
inline constexpr MotorCurrentLimits standard = {
    .run_current_rms = 1.2f,   // Strong torque; valve ~once per 2 days
    .hold_current_rms = 0.5f   // Minimal holding current
};

/** Conservative: Lower current if reliability testing shows margin */
inline constexpr MotorCurrentLimits conservative = {
    .run_current_rms = 0.9f,   // Moderate torque; higher safety margin
    .hold_current_rms = 0.3f   // Minimal standby draw
};

/** Aggressive: Maximum torque (use only if heavy load confirmed) */
inline constexpr MotorCurrentLimits high_torque = {
    .run_current_rms = 1.5f,   // Near motor rating; high torque
    .hold_current_rms = 0.6f   // Moderate holding current
};

}  // namespace profiles_17hs4401

/**
 * get_register_values()
 * Convenience function: load a predefined profile and convert to TMC2209 registers
 */
inline TMC2209RegisterValues get_register_values(
    const MotorCurrentLimits& profile) {
  return calculate_irun_ihold(profile.run_current_rms, profile.hold_current_rms);
}

/**
 * Example UART Command to Set Current (pseudocode)
 *
 * // In waste_valve_esphome.h or your UART handler:
 * const uint8_t TMC2209_ADDR_IHOLD_IRUN = 0x10;
 *
 * auto curr = waste_valve::current_config::profiles_17hs4401::balanced;
 * auto regs = waste_valve::current_config::get_register_values(curr);
 *
 * uint32_t ihold_irun_value = (regs.ihold << 16) | (regs.irun << 8);
 * waste_valve::tmc2209::write_request(
 *     tmc_address, TMC2209_ADDR_IHOLD_IRUN, ihold_irun_value, uart_request);
 *
 * // Transmit uart_request[8] over UART to driver
 * // Read reply[8] and verify with decode_reply()
 */

/**
 * Current Profiles with Expected Motor Behavior
 */
struct CurrentProfile {
  const char* name;
  MotorCurrentLimits limits;
  float expected_holding_torque_ncm;  // Approximate N·cm @ 0 RPM
  const char* use_case;
};

inline constexpr CurrentProfile all_profiles[] = {
    {
        .name = "Standard (Recommended)",
        .limits = profiles_17hs4401::standard,
        .expected_holding_torque_ncm = 35.0f,
        .use_case = "Reliable torque for infrequent valve operation (~once per 2 days)"
    },
    {
        .name = "Conservative",
        .limits = profiles_17hs4401::conservative,
        .expected_holding_torque_ncm = 27.0f,
        .use_case = "Lower current if higher safety margin needed after field testing"
    },
    {
        .name = "High Torque",
        .limits = profiles_17hs4401::high_torque,
        .expected_holding_torque_ncm = 43.0f,
        .use_case = "Only if heavy load or mechanical friction confirmed during commissioning"
    }
};

}  // namespace waste_valve::current_config

/**
 * Integration with Existing waste_valve_esphome.h
 *
 * In the lambda boot handler, after TMC2209 initialization:
 *
 *  // Apply current profile during init
 *  auto curr_profile = waste_valve::current_config::profiles_17hs4401::standard;
 *  auto regs = waste_valve::current_config::get_register_values(curr_profile);
 *
 *  uint32_t ihold_irun = (regs.ihold << 16) | (regs.irun << 8);
 *  uint8_t write_req[8];
 *  waste_valve::tmc2209::write_request(
 *      tmc_address, 0x10,  // IHOLD_IRUN register
 *      ihold_irun, write_req);
 *
 *  // Send over UART and verify reply (details in waste_valve_tmc2209.h)
 */

#endif  // WASTE_VALVE_17HS4401_CURRENT_LIMITS_H
