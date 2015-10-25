/* Copyright (c) 2011-2015, EPFL/Blue Brain Project
 *                     Cyrille Favreau <cyrille.favreau@epfl.ch>
 *
 * This file is part of BRayns
 *
 * This library is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Lesser General Public License version 3.0 as published
 * by the Free Software Foundation.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#include "Texture2D.h"

namespace brayns
{

Texture2D::Texture2D()
    : _nbChannels(0)
    , _depth(0)
    , _width(0)
    , _height(0)
{
}

void Texture2D::setRawData(unsigned char* data, size_t size)
{
    _rawData.clear();
    _rawData.assign(data, data+size);
}

}
