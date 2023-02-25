#pragma once

#include <helpers/logger.hpp>
#include <immer/vector.hpp>
#include <optional>
#include <range/v3/view.hpp>
#include <state/data-structures.hpp>

inline std::optional<state::StreamSession> get_session_by_ip(const immer::vector<state::StreamSession> &sessions,
                                                             const std::string &ip) {
  auto results = sessions |                                                                                     //
                 ranges::views::filter([&ip](const state::StreamSession &session) { return session.ip == ip; }) //
                 | ranges::views::take(1)                                                                       //
                 | ranges::to_vector;                                                                           //
  if (results.size() == 1) {
    return results[0];
  } else if (results.empty()) {
    return {};
  } else {
    logs::log(logs::warning, "Found multiple sessions for a given IP: {}", ip);
    return {};
  }
}

inline immer::vector<state::StreamSession> remove_session(const immer::vector<state::StreamSession> &sessions,
                                                          const state::StreamSession &session) {
  return sessions                                                                                                //
         | ranges::views::filter([remove_hash = session.client_cert_hash](const state::StreamSession &cur_ses) { //
             return cur_ses.client_cert_hash != remove_hash;                                                     //
           })                                                                                                    //
         | ranges::to<immer::vector<state::StreamSession>>();                                                    //
}